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

    bool closed;
} conduit_channel_t;

/* ============================================================================
 * External Class Registration
 * ============================================================================ */

static lean_external_class *g_channel_class = NULL;

static void conduit_channel_finalizer(void *ptr) {
    conduit_channel_t *ch = (conduit_channel_t *)ptr;
    if (ch) {
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
    ch->closed = false;

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
    ch->closed = false;

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
        ch->pending_value = value;
        ch->pending_ready = true;
        ch->pending_taken = false;

        /* Signal that a value is available */
        pthread_cond_signal(&ch->not_empty);

        /* Wait for receiver to take it or channel to close */
        while (!ch->pending_taken && !ch->closed) {
            pthread_cond_wait(&ch->not_full, &ch->mutex);
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
            pthread_cond_wait(&ch->not_full, &ch->mutex);
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
            pthread_cond_wait(&ch->not_empty, &ch->mutex);
        }

        if (ch->pending_ready && !ch->pending_taken) {
            /* Take the value from sender */
            lean_object *value = ch->pending_value;
            ch->pending_taken = true;
            ch->pending_ready = false;  /* Clear to prevent duplicate reads */

            /* Signal sender that we took it */
            pthread_cond_signal(&ch->not_full);

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
            pthread_cond_wait(&ch->not_empty, &ch->mutex);
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
        /* Unbuffered: can only send if receiver is waiting */
        /* For simplicity, unbuffered trySend always returns "would block"
           unless we add a waiting receiver queue */
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

        pthread_mutex_unlock(&ch->mutex);

        /* Return .ok value (constructor 0) */
        lean_object *result = lean_alloc_ctor(0, 1, 0);
        lean_ctor_set(result, 0, value);
        return lean_io_result_mk_ok(result);
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
 * Select Implementation
 *
 * For now, we implement a simple polling-based select that checks each
 * channel in order and returns the first ready one. A more sophisticated
 * implementation would register waiters on all channels.
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
                }
                /* For unbuffered, we'd need to check for waiting receiver - skip for now */
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

/*
 * conduit_select_wait : Array (Channel × Bool) → Nat → IO (Option Nat)
 *
 * Wait for any channel to become ready, with timeout in milliseconds.
 * timeout = 0 means wait forever.
 * Returns index of ready channel, or none on timeout.
 *
 * This is a simple implementation that polls with sleep.
 * A production implementation would use proper condition variables.
 */
LEAN_EXPORT lean_obj_res conduit_select_wait(
    b_lean_obj_arg cases_obj,
    b_lean_obj_arg timeout_obj,
    lean_obj_arg world
) {
    size_t timeout_ms = lean_usize_of_nat(timeout_obj);
    size_t elapsed = 0;
    const size_t poll_interval = 1; /* 1ms */

    while (timeout_ms == 0 || elapsed < timeout_ms) {
        /* Poll all channels */
        lean_object *result = conduit_select_poll(cases_obj, world);

        /* Check if we got a result (not none) */
        lean_object *inner = lean_ctor_get(result, 0);
        if (!lean_is_scalar(inner)) {
            /* Got Some result */
            return result;
        }
        lean_dec(result);

        /* Check if any channel is closed (for recv cases, closed = ready) */
        size_t n = lean_array_size(cases_obj);
        bool all_closed = true;
        for (size_t i = 0; i < n; i++) {
            lean_object *pair = lean_array_get_core(cases_obj, i);
            lean_object *ch_obj = lean_ctor_get(pair, 0);
            conduit_channel_t *ch = conduit_channel_unbox(ch_obj);

            pthread_mutex_lock(&ch->mutex);
            if (!ch->closed) {
                all_closed = false;
            }
            pthread_mutex_unlock(&ch->mutex);

            if (!all_closed) break;
        }

        if (all_closed) {
            /* All channels closed, return none */
            return lean_io_result_mk_ok(lean_box(0));
        }

        /* Sleep for poll interval */
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = poll_interval * 1000000; /* ms to ns */
        nanosleep(&ts, NULL);

        elapsed += poll_interval;
    }

    /* Timeout */
    return lean_io_result_mk_ok(lean_box(0)); /* none */
}
