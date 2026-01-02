/*
 * Conduit FFI
 * Go-style channels using POSIX pthread primitives
 */

#include <lean/lean.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <stdatomic.h>

/* ============================================================================
 * Allocation Tracking (for testing finalizers and memory leaks)
 * ============================================================================ */

static _Atomic int64_t g_channel_alloc_count = 0;
static _Atomic int64_t g_channel_free_count = 0;

/* ============================================================================
 * Select Waiter Structure (forward declaration)
 * ============================================================================ */

typedef struct conduit_select_waiter {
    pthread_cond_t *cond;         /* Waiter's condition variable */
    pthread_mutex_t *mutex;       /* Points to waiter's mutex */
    volatile bool notified;       /* Set true when any channel signals */
    struct conduit_select_waiter *next;  /* Linked list for channel's waiter list */
} conduit_select_waiter_t;

/* ============================================================================
 * Channel Structure
 * ============================================================================ */

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;     /* Signal when data available or closed */
    pthread_cond_t not_full;      /* Signal when space available or closed */

    /* Circular buffer for buffered channels */
    lean_object **buffer;
    size_t capacity;              /* 0 = unbuffered */
    size_t head;                  /* Read position */
    size_t tail;                  /* Write position */
    size_t count;                 /* Current item count */

    /* For unbuffered channels: pending value for handoff */
    lean_object *pending_value;
    bool pending_ready;           /* True if a sender is waiting */
    bool pending_taken;           /* True if receiver took the value */

    /* Track waiting threads for unbuffered send readiness */
    size_t waiting_receivers;     /* Receivers blocked waiting for data */

    /* Select waiter list (protected by channel mutex) */
    conduit_select_waiter_t *select_waiters;  /* Head of linked list */

    bool closed;
} conduit_channel_t;

/* Forward declarations for select waiter helpers */
static void select_register_waiter(conduit_channel_t *ch, conduit_select_waiter_t *w);
static void select_unregister_waiter(conduit_channel_t *ch, conduit_select_waiter_t *w);
static void select_notify_waiters(conduit_channel_t *ch);

/* ============================================================================
 * Interruptible Wait Helper
 *
 * Uses a short timeout (10ms) instead of blocking forever, allowing
 * the loop to re-check conditions periodically. This makes operations
 * interruptible by Lean's IO.cancel mechanism.
 * ============================================================================ */

#define POLL_INTERVAL_NS 10000000  /* 10ms in nanoseconds */

static int cond_wait_interruptible(pthread_cond_t *cond, pthread_mutex_t *mutex) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += POLL_INTERVAL_NS;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }
    return pthread_cond_timedwait(cond, mutex, &deadline);
}

/* ============================================================================
 * External Class Registration
 * ============================================================================ */

static lean_external_class *g_channel_class = NULL;

static void conduit_channel_finalizer(void *ptr) {
    conduit_channel_t *ch = (conduit_channel_t *)ptr;
    if (ch) {
        atomic_fetch_add(&g_channel_free_count, 1);
        pthread_mutex_lock(&ch->mutex);

        /* Release any values still in the buffer */
        if (ch->buffer) {
            while (ch->count > 0) {
                lean_dec(ch->buffer[ch->head]);
                ch->head = (ch->head + 1) % ch->capacity;
                ch->count--;
            }
            free(ch->buffer);
        }

        /* Release pending value if any */
        if (ch->pending_value) {
            lean_dec(ch->pending_value);
        }

        pthread_mutex_unlock(&ch->mutex);

        pthread_mutex_destroy(&ch->mutex);
        pthread_cond_destroy(&ch->not_empty);
        pthread_cond_destroy(&ch->not_full);
        free(ch);
    }
}

static void conduit_channel_foreach(void *ptr, b_lean_obj_arg f) {
    /* No nested Lean objects to traverse */
    (void)ptr;
    (void)f;
}

static inline lean_obj_res conduit_channel_box(conduit_channel_t *ch) {
    if (g_channel_class == NULL) {
        g_channel_class = lean_register_external_class(
            conduit_channel_finalizer,
            conduit_channel_foreach
        );
    }
    return lean_alloc_external(g_channel_class, ch);
}

static inline conduit_channel_t *conduit_channel_unbox(b_lean_obj_arg obj) {
    return (conduit_channel_t *)lean_get_external_data(obj);
}

/* ============================================================================
 * Helper: Create IO error result
 * ============================================================================ */

static lean_obj_res mk_io_error(const char *msg) {
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

/* ============================================================================
 * conduit_channel_new : Type → IO (Channel α)
 *
 * Create an unbuffered channel (capacity 0).
 * Note: Type parameter is erased at runtime, not passed to FFI.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_new(lean_obj_arg world) {
    (void)world;

    conduit_channel_t *ch = (conduit_channel_t *)malloc(sizeof(conduit_channel_t));
    if (!ch) {
        return mk_io_error("Failed to allocate channel");
    }

    if (pthread_mutex_init(&ch->mutex, NULL) != 0) {
        free(ch);
        return mk_io_error("Failed to initialize mutex");
    }

    if (pthread_cond_init(&ch->not_empty, NULL) != 0) {
        pthread_mutex_destroy(&ch->mutex);
        free(ch);
        return mk_io_error("Failed to initialize condition variable");
    }

    if (pthread_cond_init(&ch->not_full, NULL) != 0) {
        pthread_cond_destroy(&ch->not_empty);
        pthread_mutex_destroy(&ch->mutex);
        free(ch);
        return mk_io_error("Failed to initialize condition variable");
    }

    ch->buffer = NULL;
    ch->capacity = 0;
    ch->head = 0;
    ch->tail = 0;
    ch->count = 0;
    ch->pending_value = NULL;
    ch->pending_ready = false;
    ch->pending_taken = false;
    ch->waiting_receivers = 0;
    ch->select_waiters = NULL;
    ch->closed = false;

    atomic_fetch_add(&g_channel_alloc_count, 1);
    return lean_io_result_mk_ok(conduit_channel_box(ch));
}

/* ============================================================================
 * conduit_channel_new_buffered : Type → Nat → IO (Channel α)
 *
 * Create a buffered channel with given capacity.
 * Note: Type parameter is erased at runtime, not passed to FFI.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_new_buffered(
    b_lean_obj_arg capacity_obj,
    lean_obj_arg world
) {
    size_t capacity = lean_usize_of_nat(capacity_obj);

    /* Capacity 0 is equivalent to unbuffered */
    if (capacity == 0) {
        return conduit_channel_new(world);
    }

    conduit_channel_t *ch = (conduit_channel_t *)malloc(sizeof(conduit_channel_t));
    if (!ch) {
        return mk_io_error("Failed to allocate channel");
    }

    ch->buffer = (lean_object **)calloc(capacity, sizeof(lean_object *));
    if (!ch->buffer) {
        free(ch);
        return mk_io_error("Failed to allocate channel buffer");
    }

    if (pthread_mutex_init(&ch->mutex, NULL) != 0) {
        free(ch->buffer);
        free(ch);
        return mk_io_error("Failed to initialize mutex");
    }

    if (pthread_cond_init(&ch->not_empty, NULL) != 0) {
        pthread_mutex_destroy(&ch->mutex);
        free(ch->buffer);
        free(ch);
        return mk_io_error("Failed to initialize condition variable");
    }

    if (pthread_cond_init(&ch->not_full, NULL) != 0) {
        pthread_cond_destroy(&ch->not_empty);
        pthread_mutex_destroy(&ch->mutex);
        free(ch->buffer);
        free(ch);
        return mk_io_error("Failed to initialize condition variable");
    }

    ch->capacity = capacity;
    ch->head = 0;
    ch->tail = 0;
    ch->count = 0;
    ch->pending_value = NULL;
    ch->pending_ready = false;
    ch->pending_taken = false;
    ch->waiting_receivers = 0;
    ch->select_waiters = NULL;
    ch->closed = false;

    atomic_fetch_add(&g_channel_alloc_count, 1);
    return lean_io_result_mk_ok(conduit_channel_box(ch));
}

/* ============================================================================
 * conduit_channel_send : Channel α → α → IO Bool
 *
 * Blocking send. Returns false if channel is closed.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_send(
    b_lean_obj_arg ch_obj,
    lean_obj_arg value,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    /* Check if closed */
    if (ch->closed) {
        pthread_mutex_unlock(&ch->mutex);
        lean_dec(value);
        return lean_io_result_mk_ok(lean_box(0)); /* false */
    }

    if (ch->capacity == 0) {
        /* Unbuffered channel: wait for receiver */
        while (ch->pending_ready && !ch->closed) {
            cond_wait_interruptible(&ch->not_full, &ch->mutex);
        }

        if (ch->closed) {
            pthread_mutex_unlock(&ch->mutex);
            lean_dec(value);
            return lean_io_result_mk_ok(lean_box(0)); /* false */
        }

        ch->pending_value = value;
        ch->pending_ready = true;
        ch->pending_taken = false;

        /* Signal that a value is available */
        pthread_cond_signal(&ch->not_empty);
        select_notify_waiters(ch);

        /* Wait for receiver to take it or channel to close */
        while (!ch->pending_taken && !ch->closed) {
            cond_wait_interruptible(&ch->not_full, &ch->mutex);
        }

        bool success = ch->pending_taken;
        ch->pending_value = NULL;
        ch->pending_ready = false;
        ch->pending_taken = false;

        pthread_mutex_unlock(&ch->mutex);

        if (!success) {
            /* Channel closed before receiver took value */
            lean_dec(value);
        }

        return lean_io_result_mk_ok(lean_box(success ? 1 : 0));
    } else {
        /* Buffered channel: wait for space */
        while (ch->count >= ch->capacity && !ch->closed) {
            cond_wait_interruptible(&ch->not_full, &ch->mutex);
        }

        if (ch->closed) {
            pthread_mutex_unlock(&ch->mutex);
            lean_dec(value);
            return lean_io_result_mk_ok(lean_box(0)); /* false */
        }

        /* Add to buffer */
        ch->buffer[ch->tail] = value;
        ch->tail = (ch->tail + 1) % ch->capacity;
        ch->count++;

        /* Signal that data is available */
        pthread_cond_signal(&ch->not_empty);
        select_notify_waiters(ch);

        pthread_mutex_unlock(&ch->mutex);
        return lean_io_result_mk_ok(lean_box(1)); /* true */
    }
}

/* ============================================================================
 * conduit_channel_recv : Channel α → IO (Option α)
 *
 * Blocking receive. Returns none if channel is closed and empty.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_recv(
    b_lean_obj_arg ch_obj,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    if (ch->capacity == 0) {
        /* Unbuffered channel: wait for sender */
        while (!ch->pending_ready && !ch->closed) {
            ch->waiting_receivers++;
            cond_wait_interruptible(&ch->not_empty, &ch->mutex);
            ch->waiting_receivers--;
        }

        if (ch->pending_ready && !ch->pending_taken) {
            /* Take the value from sender */
            lean_object *value = ch->pending_value;
            ch->pending_taken = true;
            ch->pending_ready = false;  /* Clear to prevent duplicate reads */

            /* Signal sender that we took it */
            pthread_cond_signal(&ch->not_full);
            select_notify_waiters(ch);

            pthread_mutex_unlock(&ch->mutex);

            /* Return Some value */
            lean_object *some = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(some, 0, value);
            return lean_io_result_mk_ok(some);
        }

        /* Channel closed, no pending value */
        pthread_mutex_unlock(&ch->mutex);
        return lean_io_result_mk_ok(lean_box(0)); /* none */
    } else {
        /* Buffered channel: wait for data */
        while (ch->count == 0 && !ch->closed) {
            cond_wait_interruptible(&ch->not_empty, &ch->mutex);
        }

        if (ch->count == 0) {
            /* Channel closed and empty */
            pthread_mutex_unlock(&ch->mutex);
            return lean_io_result_mk_ok(lean_box(0)); /* none */
        }

        /* Take from buffer */
        lean_object *value = ch->buffer[ch->head];
        ch->buffer[ch->head] = NULL;
        ch->head = (ch->head + 1) % ch->capacity;
        ch->count--;

        /* Signal that space is available */
        pthread_cond_signal(&ch->not_full);
        select_notify_waiters(ch);

        pthread_mutex_unlock(&ch->mutex);

        /* Return Some value */
        lean_object *some = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(some, 0, value);
        return lean_io_result_mk_ok(some);
    }
}

/* ============================================================================
 * conduit_channel_try_send : Channel α → α → IO UInt8
 *
 * Non-blocking send. Returns 0=ok, 1=would block, 2=closed.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_try_send(
    b_lean_obj_arg ch_obj,
    lean_obj_arg value,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    if (ch->closed) {
        pthread_mutex_unlock(&ch->mutex);
        lean_dec(value);
        return lean_io_result_mk_ok(lean_box(2)); /* closed */
    }

    if (ch->capacity == 0) {
        /* Unbuffered: can send if receiver is waiting and no sender in progress */
        if (ch->waiting_receivers > 0 && !ch->pending_ready) {
            /* Perform the handoff */
            ch->pending_value = value;
            ch->pending_ready = true;
            ch->pending_taken = false;

            /* Wake one waiting receiver */
            pthread_cond_signal(&ch->not_empty);
            select_notify_waiters(ch);

            /* Wait for receiver to take it (they should be immediate) */
            while (!ch->pending_taken && !ch->closed) {
                cond_wait_interruptible(&ch->not_full, &ch->mutex);
            }

            bool success = ch->pending_taken;
            ch->pending_value = NULL;
            ch->pending_ready = false;
            ch->pending_taken = false;

            pthread_mutex_unlock(&ch->mutex);
            if (!success) lean_dec(value);
            return lean_io_result_mk_ok(lean_box(success ? 0 : 2)); /* ok or closed */
        }
        /* No receiver waiting - would block */
        pthread_mutex_unlock(&ch->mutex);
        lean_dec(value);
        return lean_io_result_mk_ok(lean_box(1)); /* would block */
    } else {
        /* Buffered: check if space available */
        if (ch->count >= ch->capacity) {
            pthread_mutex_unlock(&ch->mutex);
            lean_dec(value);
            return lean_io_result_mk_ok(lean_box(1)); /* would block */
        }

        /* Add to buffer */
        ch->buffer[ch->tail] = value;
        ch->tail = (ch->tail + 1) % ch->capacity;
        ch->count++;

        pthread_cond_signal(&ch->not_empty);
        select_notify_waiters(ch);

        pthread_mutex_unlock(&ch->mutex);
        return lean_io_result_mk_ok(lean_box(0)); /* ok */
    }
}

/* ============================================================================
 * conduit_channel_try_recv : Channel α → IO (TryResult α)
 *
 * Non-blocking receive. Returns TryResult: .ok value | .empty | .closed
 * We encode this as: 0 = closed, 1 = empty, 2 = ok (followed by value)
 * Actually, let's return a pair (tag, Option value) for simplicity.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_try_recv(
    b_lean_obj_arg ch_obj,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    if (ch->capacity == 0) {
        /* Unbuffered: check if sender is waiting */
        if (ch->pending_ready && !ch->pending_taken) {
            lean_object *value = ch->pending_value;
            ch->pending_taken = true;
            ch->pending_ready = false;  /* Clear to prevent duplicate reads */
            pthread_cond_signal(&ch->not_full);
            select_notify_waiters(ch);
            pthread_mutex_unlock(&ch->mutex);

            /* Return .ok value (constructor 0) */
            lean_object *result = lean_alloc_ctor(0, 1, 0);
            lean_ctor_set(result, 0, value);
            return lean_io_result_mk_ok(result);
        }

        if (ch->closed) {
            pthread_mutex_unlock(&ch->mutex);
            /* Return .closed (constructor 2) */
            return lean_io_result_mk_ok(lean_alloc_ctor(2, 0, 0));
        }

        pthread_mutex_unlock(&ch->mutex);
        /* Return .empty (constructor 1) */
        return lean_io_result_mk_ok(lean_alloc_ctor(1, 0, 0));
    } else {
        /* Buffered: check if data available */
        if (ch->count == 0) {
            if (ch->closed) {
                pthread_mutex_unlock(&ch->mutex);
                /* Return .closed (constructor 2) */
                return lean_io_result_mk_ok(lean_alloc_ctor(2, 0, 0));
            }
            pthread_mutex_unlock(&ch->mutex);
            /* Return .empty (constructor 1) */
            return lean_io_result_mk_ok(lean_alloc_ctor(1, 0, 0));
        }

        /* Take from buffer */
        lean_object *value = ch->buffer[ch->head];
        ch->buffer[ch->head] = NULL;
        ch->head = (ch->head + 1) % ch->capacity;
        ch->count--;

        pthread_cond_signal(&ch->not_full);
        select_notify_waiters(ch);

        pthread_mutex_unlock(&ch->mutex);

        /* Return .ok value (constructor 0) */
        lean_object *result = lean_alloc_ctor(0, 1, 0);
        lean_ctor_set(result, 0, value);
        return lean_io_result_mk_ok(result);
    }
}

/* ============================================================================
 * conduit_channel_send_timeout : Channel α → α → Nat → IO UInt8
 *
 * Blocking send with timeout. Returns 0=ok, 1=timeout, 2=closed.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_send_timeout(
    b_lean_obj_arg ch_obj,
    lean_obj_arg value,
    size_t timeout_ms,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    /* Check if closed */
    if (ch->closed) {
        pthread_mutex_unlock(&ch->mutex);
        lean_dec(value);
        return lean_io_result_mk_ok(lean_box(2)); /* closed */
    }

    /* Calculate deadline */
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }

    if (ch->capacity == 0) {
        /* Unbuffered channel: wait for receiver with timeout */
        while (ch->pending_ready && !ch->closed) {
            int rc = pthread_cond_timedwait(&ch->not_full, &ch->mutex, &deadline);
            if (rc == ETIMEDOUT) {
                pthread_mutex_unlock(&ch->mutex);
                lean_dec(value);
                return lean_io_result_mk_ok(lean_box(1)); /* timeout */
            }
        }

        if (ch->closed) {
            pthread_mutex_unlock(&ch->mutex);
            lean_dec(value);
            return lean_io_result_mk_ok(lean_box(2)); /* closed */
        }

        ch->pending_value = value;
        ch->pending_ready = true;
        ch->pending_taken = false;

        /* Signal that a value is available */
        pthread_cond_signal(&ch->not_empty);
        select_notify_waiters(ch);

        /* Wait for receiver to take it or channel to close or timeout */
        while (!ch->pending_taken && !ch->closed) {
            int rc = pthread_cond_timedwait(&ch->not_full, &ch->mutex, &deadline);
            if (rc == ETIMEDOUT) {
                /* Timeout - clean up pending state */
                ch->pending_value = NULL;
                ch->pending_ready = false;
                ch->pending_taken = false;
                pthread_mutex_unlock(&ch->mutex);
                lean_dec(value);
                return lean_io_result_mk_ok(lean_box(1)); /* timeout */
            }
        }

        bool success = ch->pending_taken;
        ch->pending_value = NULL;
        ch->pending_ready = false;
        ch->pending_taken = false;

        pthread_mutex_unlock(&ch->mutex);

        if (!success) {
            /* Channel closed before receiver took value */
            lean_dec(value);
            return lean_io_result_mk_ok(lean_box(2)); /* closed */
        }

        return lean_io_result_mk_ok(lean_box(0)); /* ok */
    } else {
        /* Buffered channel: wait for space with timeout */
        while (ch->count >= ch->capacity && !ch->closed) {
            int rc = pthread_cond_timedwait(&ch->not_full, &ch->mutex, &deadline);
            if (rc == ETIMEDOUT) {
                pthread_mutex_unlock(&ch->mutex);
                lean_dec(value);
                return lean_io_result_mk_ok(lean_box(1)); /* timeout */
            }
        }

        if (ch->closed) {
            pthread_mutex_unlock(&ch->mutex);
            lean_dec(value);
            return lean_io_result_mk_ok(lean_box(2)); /* closed */
        }

        /* Add to buffer */
        ch->buffer[ch->tail] = value;
        ch->tail = (ch->tail + 1) % ch->capacity;
        ch->count++;

        /* Signal that data is available */
        pthread_cond_signal(&ch->not_empty);
        select_notify_waiters(ch);

        pthread_mutex_unlock(&ch->mutex);
        return lean_io_result_mk_ok(lean_box(0)); /* ok */
    }
}

/* ============================================================================
 * conduit_channel_recv_timeout : Channel α → Nat → IO (Option (Option α))
 *
 * Blocking receive with timeout.
 * Returns: none = timeout, some none = closed, some (some v) = value
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_recv_timeout(
    b_lean_obj_arg ch_obj,
    size_t timeout_ms,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    /* Calculate deadline */
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }

    if (ch->capacity == 0) {
        /* Unbuffered channel: wait for sender with timeout */
        while (!ch->pending_ready && !ch->closed) {
            ch->waiting_receivers++;
            int rc = pthread_cond_timedwait(&ch->not_empty, &ch->mutex, &deadline);
            ch->waiting_receivers--;
            if (rc == ETIMEDOUT) {
                pthread_mutex_unlock(&ch->mutex);
                /* Return none (timeout) */
                return lean_io_result_mk_ok(lean_box(0));
            }
        }

        if (ch->pending_ready && !ch->pending_taken) {
            /* Take the value from sender */
            lean_object *value = ch->pending_value;
            ch->pending_taken = true;
            ch->pending_ready = false;

            /* Signal sender that we took it */
            pthread_cond_signal(&ch->not_full);
            select_notify_waiters(ch);

            pthread_mutex_unlock(&ch->mutex);

            /* Return some (some value) */
            lean_object *inner = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(inner, 0, value);
            lean_object *outer = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(outer, 0, inner);
            return lean_io_result_mk_ok(outer);
        }

        /* Channel closed, no pending value */
        pthread_mutex_unlock(&ch->mutex);
        /* Return some none (closed) */
        lean_object *outer = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(outer, 0, lean_box(0));
        return lean_io_result_mk_ok(outer);
    } else {
        /* Buffered channel: wait for data with timeout */
        while (ch->count == 0 && !ch->closed) {
            int rc = pthread_cond_timedwait(&ch->not_empty, &ch->mutex, &deadline);
            if (rc == ETIMEDOUT) {
                pthread_mutex_unlock(&ch->mutex);
                /* Return none (timeout) */
                return lean_io_result_mk_ok(lean_box(0));
            }
        }

        if (ch->count == 0) {
            /* Channel closed and empty */
            pthread_mutex_unlock(&ch->mutex);
            /* Return some none (closed) */
            lean_object *outer = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(outer, 0, lean_box(0));
            return lean_io_result_mk_ok(outer);
        }

        /* Take from buffer */
        lean_object *value = ch->buffer[ch->head];
        ch->buffer[ch->head] = NULL;
        ch->head = (ch->head + 1) % ch->capacity;
        ch->count--;

        /* Signal that space is available */
        pthread_cond_signal(&ch->not_full);
        select_notify_waiters(ch);

        pthread_mutex_unlock(&ch->mutex);

        /* Return some (some value) */
        lean_object *inner = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(inner, 0, value);
        lean_object *outer = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(outer, 0, inner);
        return lean_io_result_mk_ok(outer);
    }
}

/* ============================================================================
 * conduit_channel_close : Channel α → IO Unit
 *
 * Close the channel. Wakes all waiting senders/receivers.
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_close(
    b_lean_obj_arg ch_obj,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);

    if (!ch->closed) {
        ch->closed = true;

        /* Wake all waiting threads */
        pthread_cond_broadcast(&ch->not_empty);
        pthread_cond_broadcast(&ch->not_full);
        select_notify_waiters(ch);
    }

    pthread_mutex_unlock(&ch->mutex);

    return lean_io_result_mk_ok(lean_box(0));
}

/* ============================================================================
 * conduit_channel_is_closed : Channel α → IO Bool
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_is_closed(
    b_lean_obj_arg ch_obj,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);
    bool closed = ch->closed;
    pthread_mutex_unlock(&ch->mutex);

    return lean_io_result_mk_ok(lean_box(closed ? 1 : 0));
}

/* ============================================================================
 * conduit_channel_len : Channel α → IO Nat
 *
 * Get current number of items in buffer (0 for unbuffered).
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_len(
    b_lean_obj_arg ch_obj,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    pthread_mutex_lock(&ch->mutex);
    size_t len = ch->count;
    pthread_mutex_unlock(&ch->mutex);

    return lean_io_result_mk_ok(lean_usize_to_nat(len));
}

/* ============================================================================
 * conduit_channel_capacity : Channel α → IO Nat
 *
 * Get buffer capacity (0 for unbuffered).
 * ============================================================================ */

LEAN_EXPORT lean_obj_res conduit_channel_capacity(
    b_lean_obj_arg ch_obj,
    lean_obj_arg world
) {
    (void)world;
    conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

    /* Capacity is immutable, no lock needed */
    return lean_io_result_mk_ok(lean_usize_to_nat(ch->capacity));
}

/* ============================================================================
 * Select Waiter Helpers
 * ============================================================================ */

/* Register a select waiter on a channel (called with channel mutex held) */
static void select_register_waiter(conduit_channel_t *ch, conduit_select_waiter_t *w) {
    w->next = ch->select_waiters;
    ch->select_waiters = w;
}

/* Unregister a select waiter from a channel (called with channel mutex held) */
static void select_unregister_waiter(conduit_channel_t *ch, conduit_select_waiter_t *w) {
    conduit_select_waiter_t **pp = &ch->select_waiters;
    while (*pp != NULL) {
        if (*pp == w) {
            *pp = w->next;
            return;
        }
        pp = &(*pp)->next;
    }
}

/* Notify all select waiters on a channel (called with channel mutex held) */
static void select_notify_waiters(conduit_channel_t *ch) {
    conduit_select_waiter_t *w = ch->select_waiters;
    while (w != NULL) {
        pthread_mutex_lock(w->mutex);
        w->notified = true;
        pthread_cond_signal(w->cond);
        pthread_mutex_unlock(w->mutex);
        w = w->next;
    }
}

/* ============================================================================
 * Select Implementation
 * ============================================================================ */

/*
 * conduit_select_poll : Array (Channel × Bool) → IO (Option Nat)
 *
 * Poll an array of (channel, is_send) pairs. Returns index of first ready
 * channel, or none if none are ready.
 *
 * is_send: true = check if can send, false = check if can recv
 */
LEAN_EXPORT lean_obj_res conduit_select_poll(
    b_lean_obj_arg cases_obj,
    lean_obj_arg world
) {
    (void)world;

    size_t n = lean_array_size(cases_obj);

    for (size_t i = 0; i < n; i++) {
        lean_object *pair = lean_array_get_core(cases_obj, i);
        lean_object *ch_obj = lean_ctor_get(pair, 0);
        bool is_send = lean_unbox(lean_ctor_get(pair, 1)) != 0;

        conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

        pthread_mutex_lock(&ch->mutex);

        bool ready = false;

        if (is_send) {
            /* Can send if: not closed AND (buffered with space OR unbuffered with waiting receiver) */
            if (!ch->closed) {
                if (ch->capacity > 0 && ch->count < ch->capacity) {
                    ready = true;
                } else if (ch->capacity == 0 && ch->waiting_receivers > 0 && !ch->pending_ready) {
                    /* Unbuffered with waiting receiver and no send in progress */
                    ready = true;
                }
            }
        } else {
            /* Can recv if: has data OR (unbuffered with pending and not yet taken) OR closed */
            if (ch->count > 0 || (ch->pending_ready && !ch->pending_taken) || ch->closed) {
                ready = true;
            }
        }

        pthread_mutex_unlock(&ch->mutex);

        if (ready) {
            /* Return Some i */
            lean_object *some = lean_alloc_ctor(1, 1, 0);
            lean_ctor_set(some, 0, lean_usize_to_nat(i));
            return lean_io_result_mk_ok(some);
        }
    }

    /* None ready */
    return lean_io_result_mk_ok(lean_box(0)); /* none */
}

/* Comparison function for sorting channels by address */
static int compare_channels(const void *a, const void *b) {
    conduit_channel_t *ca = *(conduit_channel_t **)a;
    conduit_channel_t *cb = *(conduit_channel_t **)b;
    if (ca < cb) return -1;
    if (ca > cb) return 1;
    return 0;
}

/*
 * conduit_select_wait : Array (Channel × Bool) → Nat → IO (Option Nat)
 *
 * Wait for any channel to become ready, with timeout in milliseconds.
 * timeout = 0 means wait forever.
 * Returns index of ready channel, or none on timeout.
 *
 * Uses proper condition variable signaling for immediate wake-up.
 */
LEAN_EXPORT lean_obj_res conduit_select_wait(
    b_lean_obj_arg cases_obj,
    b_lean_obj_arg timeout_obj,
    lean_obj_arg world
) {
    size_t n = lean_array_size(cases_obj);
    if (n == 0) {
        return lean_io_result_mk_ok(lean_box(0)); /* none */
    }

    size_t timeout_ms = lean_usize_of_nat(timeout_obj);
    lean_object *result;
    lean_object *inner;

retry:
    /* 1. First poll without waiting (fast path) */
    result = conduit_select_poll(cases_obj, world);
    inner = lean_ctor_get(result, 0);
    if (!lean_is_scalar(inner)) {
        return result; /* Already ready */
    }
    lean_dec(result);

    /* 2. Collect unique channels and sort by address (for deadlock prevention) */
    conduit_channel_t **channels = (conduit_channel_t **)malloc(n * sizeof(conduit_channel_t *));
    if (!channels) {
        return lean_io_result_mk_ok(lean_box(0)); /* none on alloc failure */
    }

    for (size_t i = 0; i < n; i++) {
        lean_object *pair = lean_array_get_core(cases_obj, i);
        lean_object *ch_obj = lean_ctor_get(pair, 0);
        channels[i] = conduit_channel_unbox(ch_obj);
    }

    /* Sort by address to prevent deadlock when locking multiple channels */
    qsort(channels, n, sizeof(conduit_channel_t *), compare_channels);

    /* Remove duplicates (keep unique channels only) */
    size_t unique_count = 0;
    for (size_t i = 0; i < n; i++) {
        if (unique_count == 0 || channels[i] != channels[unique_count - 1]) {
            channels[unique_count++] = channels[i];
        }
    }

    /* 3. Create waiter structure */
    pthread_mutex_t wait_mutex;
    pthread_cond_t wait_cond;
    pthread_mutex_init(&wait_mutex, NULL);
    pthread_cond_init(&wait_cond, NULL);

    conduit_select_waiter_t waiter = {
        .cond = &wait_cond,
        .mutex = &wait_mutex,
        .notified = false,
        .next = NULL
    };

    /* 4. Lock all channels (in sorted order) and register waiter */
    for (size_t i = 0; i < unique_count; i++) {
        pthread_mutex_lock(&channels[i]->mutex);
        select_register_waiter(channels[i], &waiter);
    }

    /* 5. Check if any ready now (may have become ready while registering) */
    bool found_ready = false;
    for (size_t i = 0; i < n && !found_ready; i++) {
        lean_object *pair = lean_array_get_core(cases_obj, i);
        lean_object *ch_obj = lean_ctor_get(pair, 0);
        bool is_send = lean_unbox(lean_ctor_get(pair, 1)) != 0;
        conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

        /* Note: we already hold the lock on this channel */
        if (is_send) {
            if (!ch->closed) {
                if (ch->capacity > 0 && ch->count < ch->capacity) {
                    found_ready = true;
                } else if (ch->capacity == 0 && ch->waiting_receivers > 0 && !ch->pending_ready) {
                    found_ready = true;
                }
            }
        } else {
            if (ch->count > 0 || (ch->pending_ready && !ch->pending_taken) || ch->closed) {
                found_ready = true;
            }
        }
    }

    if (found_ready) {
        /* Unregister and unlock immediately */
        for (size_t i = unique_count; i > 0; i--) {
            select_unregister_waiter(channels[i-1], &waiter);
            pthread_mutex_unlock(&channels[i-1]->mutex);
        }
        pthread_cond_destroy(&wait_cond);
        pthread_mutex_destroy(&wait_mutex);
        free(channels);
        return conduit_select_poll(cases_obj, world);
    }

    /* 6. Not ready - unlock channels and wait on condition */
    pthread_mutex_lock(&wait_mutex);
    for (size_t i = unique_count; i > 0; i--) {
        pthread_mutex_unlock(&channels[i-1]->mutex);
    }

    /* 7. Wait loop with timeout */
    struct timespec deadline;
    if (timeout_ms > 0) {
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += timeout_ms / 1000;
        deadline.tv_nsec += (timeout_ms % 1000) * 1000000;
        if (deadline.tv_nsec >= 1000000000) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000;
        }
    }

    while (!waiter.notified) {
        if (timeout_ms == 0) {
            cond_wait_interruptible(&wait_cond, &wait_mutex);
        } else {
            int rc = pthread_cond_timedwait(&wait_cond, &wait_mutex, &deadline);
            if (rc == ETIMEDOUT) {
                break;
            }
        }
    }
    pthread_mutex_unlock(&wait_mutex);

    /* 8. Unregister from all channels */
    for (size_t i = 0; i < unique_count; i++) {
        pthread_mutex_lock(&channels[i]->mutex);
        select_unregister_waiter(channels[i], &waiter);
        pthread_mutex_unlock(&channels[i]->mutex);
    }

    /* 9. Final poll to get ready index */
    result = conduit_select_poll(cases_obj, world);

    /* 10. Cleanup */
    pthread_cond_destroy(&wait_cond);
    pthread_mutex_destroy(&wait_mutex);
    free(channels);

    if (timeout_ms == 0) {
        lean_object *final_inner = lean_ctor_get(result, 0);
        if (lean_is_scalar(final_inner)) {
            bool all_send_closed = true;
            for (size_t i = 0; i < n; i++) {
                lean_object *pair = lean_array_get_core(cases_obj, i);
                lean_object *ch_obj = lean_ctor_get(pair, 0);
                bool is_send = lean_unbox(lean_ctor_get(pair, 1)) != 0;

                if (!is_send) {
                    all_send_closed = false;
                    break;
                }

                conduit_channel_t *ch = conduit_channel_unbox(ch_obj);
                pthread_mutex_lock(&ch->mutex);
                bool closed = ch->closed;
                pthread_mutex_unlock(&ch->mutex);

                if (!closed) {
                    all_send_closed = false;
                    break;
                }
            }

            if (!all_send_closed) {
                lean_dec(result);
                goto retry;
            }
        }
    }

    return result;
}

/* ============================================================================
 * Allocation Statistics (for testing finalizers and memory leaks)
 * ============================================================================ */

/*
 * conduit_get_alloc_stats : IO (Int × Int)
 *
 * Returns (alloc_count, free_count) for testing that finalizers run correctly.
 */
LEAN_EXPORT lean_obj_res conduit_get_alloc_stats(lean_obj_arg world) {
    (void)world;
    int64_t allocs = atomic_load(&g_channel_alloc_count);
    int64_t frees = atomic_load(&g_channel_free_count);
    /* Return tuple (allocs, frees) as (Nat, Nat) */
    lean_object *pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, lean_uint64_to_nat((uint64_t)allocs));
    lean_ctor_set(pair, 1, lean_uint64_to_nat((uint64_t)frees));
    return lean_io_result_mk_ok(pair);
}

/*
 * conduit_reset_alloc_stats : IO Unit
 *
 * Resets allocation counters to zero (useful between tests).
 */
LEAN_EXPORT lean_obj_res conduit_reset_alloc_stats(lean_obj_arg world) {
    (void)world;
    atomic_store(&g_channel_alloc_count, 0);
    atomic_store(&g_channel_free_count, 0);
    return lean_io_result_mk_ok(lean_box(0));
}
