#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <stdbool.h>
#include <unistd.h>

#include "pxs_result.h"

#define MY_CXT_KEY "Promise::XS::_guts" XS_VERSION

#define BASE_CLASS "Promise::XS"

#define PROMISE_CLASS "Promise::XS::Promise"
#define PROMISE_CLASS_TYPE Promise__XS__Promise

#define DEFERRED_CLASS "Promise::XS::Deferred"
#define DEFERRED_CLASS_TYPE Promise__XS__Deferred

#ifdef PL_phase
#define PXS_IS_GLOBAL_DESTRUCTION PL_phase == PERL_PHASE_DESTRUCT
#else
#define PXS_IS_GLOBAL_DESTRUCTION PL_dirty
#endif

typedef struct xspr_callback_s xspr_callback_t;
typedef struct xspr_promise_s xspr_promise_t;
typedef struct xspr_callback_queue_s xspr_callback_queue_t;

typedef enum {
    XSPR_STATE_NONE,
    XSPR_STATE_PENDING,
    XSPR_STATE_FINISHED,
} xspr_promise_state_t;

typedef enum {

    // from then() or catch()
    XSPR_CALLBACK_PERL,

    // from finally()
    XSPR_CALLBACK_FINALLY,

    // from a promise given to a then() or catch() callback
    XSPR_CALLBACK_CHAIN,

    // from a promise given to a finally() callback
    XSPR_CALLBACK_FINALLY_CHAIN
} xspr_callback_type_t;

struct xspr_callback_s {
    xspr_callback_type_t type;

    union {
        struct {
            SV* on_resolve;
            SV* on_reject;
            xspr_promise_t* next;
        } perl;

        struct {
            SV* on_finally;
            xspr_promise_t* next;
        } finally;

        xspr_promise_t* chain;

        struct {
            xspr_result_t* original_result;
            xspr_promise_t* chain_promise;
        } finally_chain;
    };
};

struct xspr_promise_s {
    xspr_promise_state_t state;
    pid_t detect_leak_pid;
    int refs;
    union {
        struct {
            xspr_callback_t** callbacks;
            int callbacks_count;
        } pending;
        struct {
            xspr_result_t *result;
        } finished;
    };
};

struct xspr_callback_queue_s {
    xspr_promise_t* origin;
    xspr_callback_t* callback;
    xspr_callback_queue_t* next;
};

xspr_callback_t* xspr_callback_new_perl(pTHX_ SV* on_resolve, SV* on_reject, xspr_promise_t* next);
xspr_callback_t* xspr_callback_new_chain(pTHX_ xspr_promise_t* chain);
xspr_callback_t* xspr_callback_new_finally_chain(pTHX_ xspr_result_t* original_result, xspr_promise_t* next_promise);
void xspr_callback_process(pTHX_ xspr_callback_t* callback, xspr_promise_t* origin);
void xspr_callback_free(pTHX_ xspr_callback_t* callback);

xspr_promise_t* xspr_promise_new(pTHX);
void xspr_promise_then(pTHX_ xspr_promise_t* promise, xspr_callback_t* callback);
void xspr_promise_finish(pTHX_ xspr_promise_t* promise, xspr_result_t *result);
void xspr_promise_incref(pTHX_ xspr_promise_t* promise);
void xspr_promise_decref(pTHX_ xspr_promise_t* promise);

xspr_result_t* xspr_invoke_perl(pTHX_ SV* perl_fn, SV* input);
xspr_promise_t* xspr_promise_from_sv(pTHX_ SV* input);


typedef struct {
    xspr_callback_queue_t* queue_head;
    xspr_callback_queue_t* queue_tail;
    int in_flush;
    int backend_scheduled;
#ifdef USE_ITHREADS
    tTHX owner;
#endif
    SV* conversion_helper;
    SV* pxs_flush_cr;
    HV* pxs_base_stash;
    HV* pxs_promise_stash;
    HV* pxs_deferred_stash;
    SV* deferral_cr;
    SV* deferral_arg;
} my_cxt_t;

typedef struct {
    xspr_promise_t* promise;
} DEFERRED_CLASS_TYPE;

typedef struct {
    xspr_promise_t* promise;
} PROMISE_CLASS_TYPE;

START_MY_CXT

/* Process a single callback */
void xspr_callback_process(pTHX_ xspr_callback_t* callback, xspr_promise_t* origin)
{
    assert(origin->state == XSPR_STATE_FINISHED);

    if (callback->type == XSPR_CALLBACK_CHAIN) {
        xspr_promise_finish(aTHX_ callback->chain, origin->finished.result);

    } else if (callback->type == XSPR_CALLBACK_FINALLY_CHAIN) {
fprintf(stderr, "resolving finally chain\n");
        xspr_promise_finish(aTHX_
            callback->finally_chain.chain_promise,
            (origin->finished.result->state == XSPR_RESULT_REJECTED) ? origin->finished.result : callback->finally_chain.original_result
        );

    } else if (callback->type == XSPR_CALLBACK_PERL || callback->type == XSPR_CALLBACK_FINALLY) {
        SV* callback_fn;

        xspr_promise_t* next_promise;

        if (callback->type == XSPR_CALLBACK_FINALLY) {
            callback_fn = callback->finally.on_finally;
            next_promise = callback->finally.next;
        } else {
            next_promise = callback->perl.next;

            if (origin->finished.result->state == XSPR_RESULT_RESOLVED) {
                callback_fn = callback->perl.on_resolve;
            } else if (origin->finished.result->state == XSPR_RESULT_REJECTED) {
                callback_fn = callback->perl.on_reject;

                if (callback_fn && SvOK(callback_fn)) {
    // fprintf(stderr, "promise %p: setting rejection should warn = false\n", origin);
                    origin->finished.result->rejection_should_warn = false;
                }

                // If we got a REJECTED callback, then we’re handling the rejection.
                // Even if not, though, we’re creating another promise, and that
                // promise will either handle the rejection or report non-handling.
                // So, in either case, we want to clear the unhandled rejection.
                // origin->unhandled_rejection = NULL;
            } else {
                callback_fn = NULL; /* Be quiet, bad compiler! */
                assert(0);
            }
        }

        if (callback_fn != NULL) {
            xspr_result_t* callback_result;

//fprintf(stderr,"running perl callback\n");
//sv_dump(callback_fn);
            callback_result = xspr_invoke_perl(aTHX_
                                      callback_fn,
                                      (callback->type == XSPR_CALLBACK_FINALLY) ? NULL : origin->finished.result->result
                                      );
//fprintf(stderr,"after callback\n");

            if (next_promise != NULL) {
                int returned_promise = 0;

                if (callback_result->state == XSPR_RESULT_RESOLVED) {
                    xspr_promise_t* promise = xspr_promise_from_sv(aTHX_ callback_result->result);
                    if (promise != NULL) {
                        if ( promise == next_promise) {
                            /* This is an extreme corner case the A+ spec made us implement: we need to reject
                            * cases where the promise created from then() is passed back to its own callback */
                            xspr_result_t* chain_error = xspr_result_from_error(aTHX_ "TypeError");
                            xspr_promise_finish(aTHX_ next_promise, chain_error);

                            xspr_result_decref(aTHX_ chain_error);
                        }
                        else {
                            /* Fairly normal case: we returned a promise from the callback */
                            xspr_callback_t* chainback;

                            if (callback->type == XSPR_CALLBACK_FINALLY) {
fprintf(stderr, "creating callback chain from finally callback\n");
                                chainback = xspr_callback_new_finally_chain(aTHX_ origin->finished.result, next_promise);
                            }
                            else {
                                chainback = xspr_callback_new_chain(aTHX_ next_promise);
                            }

                            xspr_promise_then(aTHX_ promise, chainback);
                            // promise->unhandled_rejection = NULL;
                        }

                        xspr_promise_decref(aTHX_ promise);
                        returned_promise = 1;
                    }
                }

                if (!returned_promise) {
                    xspr_result_t* final_result;
                    bool final_result_needs_decref = false;

                    if ((callback->type == XSPR_CALLBACK_FINALLY) && (callback_result->state == XSPR_RESULT_RESOLVED)) {
                        // CLONE_RESULT(origin->finished.result, final_result);
                        // final_result_needs_decref = true;
                        final_result = origin->finished.result;
                    }
                    else {
                        final_result = callback_result;
                    }
//fprintf(stderr, "settling promise %p\n", next_promise);
//sv_dump(final_result->result);
                    xspr_promise_finish(aTHX_ next_promise, final_result);

                    if (final_result_needs_decref) {
                        xspr_result_decref(aTHX_ final_result);
                    }
                }
            }

            xspr_result_decref(aTHX_ callback_result);

        } else if (next_promise) {
            /* No callback, so we're just passing the result along. */
            xspr_result_t* result = origin->finished.result;
            xspr_promise_finish(aTHX_ next_promise, result);
        }

    } else {
        assert(0);
    }
}

/* Frees the xspr_callback_t structure */
void xspr_callback_free(pTHX_ xspr_callback_t *callback)
{
    if (callback->type == XSPR_CALLBACK_CHAIN) {
        xspr_promise_decref(aTHX_ callback->chain);

    } else if (callback->type == XSPR_CALLBACK_PERL) {
        SvREFCNT_dec(callback->perl.on_resolve);
        SvREFCNT_dec(callback->perl.on_reject);
        if (callback->perl.next != NULL)
            xspr_promise_decref(aTHX_ callback->perl.next);

    } else if (callback->type == XSPR_CALLBACK_FINALLY) {
        SvREFCNT_dec(callback->finally.on_finally);
        if (callback->finally.next != NULL)
            xspr_promise_decref(aTHX_ callback->finally.next);

    } else if (callback->type == XSPR_CALLBACK_FINALLY_CHAIN) {
        xspr_promise_decref(aTHX_ callback->finally_chain.chain_promise);
        xspr_result_decref(aTHX_ callback->finally_chain.original_result);

    } else {
        assert(0);
    }

    Safefree(callback);
}

/* Process the queue until it's empty */
void xspr_queue_flush(pTHX)
{
    dMY_CXT;

    if (MY_CXT.in_flush) {
        /* XXX: is there a reasonable way to trigger this? */
        warn("Rejecting request to flush promises queue: already processing");
        return;
    }
    MY_CXT.in_flush = 1;

    while (MY_CXT.queue_head != NULL) {
        /* Save some typing... */
        xspr_callback_queue_t *cur = MY_CXT.queue_head;

        /* Process the callback. This could trigger some Perl code, meaning we
         * could end up with additional queue entries after this */
        xspr_callback_process(aTHX_ cur->callback, cur->origin);

        /* Free-ing the callback structure could theoretically trigger DESTROY subs,
         * enqueueing new callbacks, so we can't assume the loop ends here! */
        MY_CXT.queue_head = cur->next;
        if (cur->next == NULL) {
            MY_CXT.queue_tail = NULL;
        }

        /* Destroy the structure */
        xspr_callback_free(aTHX_ cur->callback);
        xspr_promise_decref(aTHX_ cur->origin);
        Safefree(cur);
    }

    MY_CXT.in_flush = 0;
    MY_CXT.backend_scheduled = 0;
}

/* Add a callback invocation into the queue for the given origin promise.
 * Takes ownership of the callback structure */
void xspr_queue_add(pTHX_ xspr_callback_t* callback, xspr_promise_t* origin)
{
    dMY_CXT;

    xspr_callback_queue_t* entry;
    Newxz(entry, 1, xspr_callback_queue_t);
    entry->origin = origin;
    xspr_promise_incref(aTHX_ entry->origin);
    entry->callback = callback;

    if (MY_CXT.queue_head == NULL) {
        assert(MY_CXT.queue_tail == NULL);
        /* Empty queue, so now it's just us */
        MY_CXT.queue_head = entry;
        MY_CXT.queue_tail = entry;

    } else {
        assert(MY_CXT.queue_tail != NULL);
        /* Existing queue, add to the tail */
        MY_CXT.queue_tail->next = entry;
        MY_CXT.queue_tail = entry;
    }
}

void _call_with_1_or_2_args( pTHX_ SV* cb, SV* maybe_arg0, SV* arg1 ) {
    // --- Almost all copy-paste from “perlcall” … blegh!
    dSP;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);

    if (maybe_arg0) {
        EXTEND(SP, 2);
        PUSHs(maybe_arg0);
    }
    else {
        EXTEND(SP, 1);
    }

    PUSHs( arg1 );
    PUTBACK;

    call_sv(cb, G_VOID);

    FREETMPS;
    LEAVE;

    return;
}

void xspr_queue_maybe_schedule(pTHX)
{
    dMY_CXT;
    if (MY_CXT.queue_head == NULL || MY_CXT.backend_scheduled || MY_CXT.in_flush) {
        return;
    }

    MY_CXT.backend_scheduled = 1;
    /* We trust our backends to be sane, so little guarding against errors here */

    if (!MY_CXT.pxs_flush_cr) {
        HV *stash = gv_stashpv(DEFERRED_CLASS, 0);
        GV* method_gv = gv_fetchmethod_autoload(stash, "___flush", FALSE);
        if (method_gv != NULL && isGV(method_gv) && GvCV(method_gv) != NULL) {
            MY_CXT.pxs_flush_cr = newRV_inc( (SV*)GvCV(method_gv) );
        }
        else {
            assert(0);
        }
    }

    _call_with_1_or_2_args(aTHX_ MY_CXT.deferral_cr, MY_CXT.deferral_arg, MY_CXT.pxs_flush_cr);
}

/* Invoke the user's perl code. We need to be really sure this doesn't return early via croak/next/etc. */
xspr_result_t* xspr_invoke_perl(pTHX_ SV* perl_fn, SV* input)
{
    dSP;
    unsigned count, i;
    SV* error;
    xspr_result_t* result;

    if (!SvROK(perl_fn)) {
//sv_dump(perl_fn);
        return xspr_result_from_error(aTHX_ "promise callbacks need to be a CODE reference");
    }

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);

    if (input != NULL) {
        EXTEND(SP, 1);
//fprintf(stderr, "pushing %p (%d of %d)\n", inputs[i], 1 + i, input_count);
//sv_dump(inputs[i]);
        PUSHs(input);
    }
    PUTBACK;

    /* Clear $_ so that callbacks don't end up talking to each other by accident */
    SAVE_DEFSV;
    DEFSV_set(sv_newmortal());
//fprintf(stderr,"before call_sv (inputs=%d)\n", input_count);

    count = call_sv(perl_fn, G_EVAL | G_SCALAR);

    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        result = xspr_result_new(aTHX_ XSPR_RESULT_REJECTED);
        result->result = newSVsv(ERRSV);
    } else {
        result = xspr_result_new(aTHX_ XSPR_RESULT_RESOLVED);
//fprintf(stderr,"after call_sv; count = %d\n", count);
        result->result = count ? SvREFCNT_inc(POPs) : &PL_sv_undef;
    }
    PUTBACK;

    FREETMPS;
    LEAVE;

    return result;
}

void xspr_immediate_process(pTHX_ xspr_callback_t* callback, xspr_promise_t* promise)
{
    xspr_callback_process(aTHX_ callback, promise);

    /* Destroy the structure */
    xspr_callback_free(aTHX_ callback);
}

/* Transitions a promise from pending to finished, using the given result */
void xspr_promise_finish(pTHX_ xspr_promise_t* promise, xspr_result_t* result)
{
    dMY_CXT;

    assert(promise->state == XSPR_STATE_PENDING);
    xspr_callback_t** pending_callbacks = promise->pending.callbacks;
    int count = promise->pending.callbacks_count;

/*
    if (count == 0 && result->state == XSPR_RESULT_REJECTED) {
        promise->unhandled_rejection = result;
    }
*/

    promise->state = XSPR_STATE_FINISHED;
    promise->finished.result = result;
    xspr_result_incref(aTHX_ promise->finished.result);

    //fprintf(stderr, "finishing promise %p, result %p\n", promise, result);
    unsigned i;
    for (i = 0; i < count; i++) {
//fprintf(stderr, "pre-check\n");
        if (pending_callbacks[i]->type == XSPR_CALLBACK_PERL && result->state == XSPR_RESULT_REJECTED && result->rejection_should_warn) {
//fprintf(stderr, "check1\n");
            SV* on_reject = pending_callbacks[i]->perl.on_reject;
//fprintf(stderr, "check2 %p\n", on_reject);
            if (on_reject && SvOK(on_reject)) {
//fprintf(stderr, "%p: have on_reject handler; setting rejection should warn = false\n", promise);
                result->rejection_should_warn = false;
            }
        }
//fprintf(stderr, "past check\n");

        if (MY_CXT.deferral_cr) {
            xspr_queue_add(aTHX_ pending_callbacks[i], promise);
        }
        else {
            xspr_immediate_process(aTHX_ pending_callbacks[i], promise);
        }
    }

    if (MY_CXT.deferral_cr) {
        xspr_queue_maybe_schedule(aTHX);
    }
    //fprintf(stderr, "DONE finishing promise %p, result %p\n", promise, result);

    Safefree(pending_callbacks);
}

/* Increments the ref count for xspr_promise_t */
void xspr_promise_incref(pTHX_ xspr_promise_t* promise)
{
    (promise->refs)++;
}

/* Decrements the ref count for the xspr_promise_t, freeing the structure if needed */
void xspr_promise_decref(pTHX_ xspr_promise_t *promise)
{
    if (--(promise->refs) == 0) {
//fprintf(stderr,"starting reap of promise %p\n", promise);
        if (promise->state == XSPR_STATE_PENDING) {
            /* XXX: is this a bad thing we should warn for? */
            int count = promise->pending.callbacks_count;
            xspr_callback_t **callbacks = promise->pending.callbacks;
            int i;
            for (i = 0; i < count; i++) {
                xspr_callback_free(aTHX_ callbacks[i]);
            }
            Safefree(callbacks);

        } else if (promise->state == XSPR_STATE_FINISHED) {
/*
            if (promise->finished.result->state == XSPR_RESULT_REJECTED && promise->unhandled_rejection && promise->unhandled_rejection->result) {
                _warn_unhandled_rejection(aTHX_ promise->unhandled_rejection->result);
            }
*/

            xspr_result_decref(aTHX_ promise->finished.result);

        } else {
            assert(0);
        }

        Safefree(promise);
//fprintf(stderr,"done reap of promise %p\n", promise);
    }
}

/* Creates a new promise. It's that simple. */
xspr_promise_t* xspr_promise_new(pTHX)
{
    xspr_promise_t* promise;
    Newxz(promise, 1, xspr_promise_t);
    promise->refs = 1;
    promise->state = XSPR_STATE_PENDING;
    // promise->unhandled_rejection = NULL;
    return promise;
}

xspr_callback_t* xspr_callback_new_perl(pTHX_ SV* on_resolve, SV* on_reject, xspr_promise_t* next)
{
    xspr_callback_t* callback;
    Newxz(callback, 1, xspr_callback_t);
    callback->type = XSPR_CALLBACK_PERL;
    if (SvOK(on_resolve))
        callback->perl.on_resolve = newSVsv(on_resolve);
    if (SvOK(on_reject))
        callback->perl.on_reject = newSVsv(on_reject);
    callback->perl.next = next;
    if (next)
        xspr_promise_incref(aTHX_ callback->perl.next);
    return callback;
}

xspr_callback_t* xspr_callback_new_finally(pTHX_ SV* on_finally, xspr_promise_t* next)
{
    xspr_callback_t* callback;
    Newxz(callback, 1, xspr_callback_t);
    callback->type = XSPR_CALLBACK_FINALLY;
    if (SvOK(on_finally))
        callback->finally.on_finally = newSVsv(on_finally);
    callback->finally.next = next;
    if (next)
        xspr_promise_incref(aTHX_ callback->finally.next);
    return callback;
}

xspr_callback_t* xspr_callback_new_chain(pTHX_ xspr_promise_t* chain)
{
    xspr_callback_t* callback;
    Newxz(callback, 1, xspr_callback_t);
    callback->type = XSPR_CALLBACK_CHAIN;
    callback->chain = chain;
    xspr_promise_incref(aTHX_ chain);
    return callback;
}

xspr_callback_t* xspr_callback_new_finally_chain(pTHX_ xspr_result_t* original_result, xspr_promise_t* next_promise)
{
    xspr_callback_t* callback;
    Newxz(callback, 1, xspr_callback_t);
    callback->type = XSPR_CALLBACK_FINALLY_CHAIN;
    callback->finally_chain.original_result = original_result;
    callback->finally_chain.chain_promise = next_promise;
    xspr_result_incref(aTHX_ original_result);
    xspr_promise_incref(aTHX_ next_promise);
    return callback;
}

/* Adds a then to the promise. Takes ownership of the callback */
void xspr_promise_then(pTHX_ xspr_promise_t* promise, xspr_callback_t* callback)
{
    dMY_CXT;

    if (promise->state == XSPR_STATE_PENDING) {
        promise->pending.callbacks_count++;
        Renew(promise->pending.callbacks, promise->pending.callbacks_count, xspr_callback_t*);
        promise->pending.callbacks[promise->pending.callbacks_count-1] = callback;

    } else if (promise->state == XSPR_STATE_FINISHED) {

        if (MY_CXT.deferral_cr) {
            xspr_queue_add(aTHX_ callback, promise);
            xspr_queue_maybe_schedule(aTHX);
        }
        else {
            xspr_immediate_process(aTHX_ callback, promise);
        }
    } else {
        assert(0);
    }
}

/* Returns a promise if the given SV is a thenable. Ownership handed to the caller! */
xspr_promise_t* xspr_promise_from_sv(pTHX_ SV* input)
{
    if (input == NULL || !sv_isobject(input)) {
        return NULL;
    }

    /* If we got one of our own promises: great, not much to do here! */
    if (sv_derived_from(input, PROMISE_CLASS)) {
        IV tmp = SvIV((SV*)SvRV(input));
        PROMISE_CLASS_TYPE* promise = INT2PTR(PROMISE_CLASS_TYPE*, tmp);
        xspr_promise_incref(aTHX_ promise->promise);
        return promise->promise;
    }

    /* Maybe we got another type of promise. Let's convert it */
    GV* method_gv = gv_fetchmethod_autoload(SvSTASH(SvRV(input)), "then", FALSE);
    if (method_gv != NULL && isGV(method_gv) && GvCV(method_gv) != NULL) {
        dMY_CXT;

        xspr_result_t* new_result = xspr_invoke_perl(aTHX_ MY_CXT.conversion_helper, input);
        if (new_result->state == XSPR_RESULT_RESOLVED &&
            SvROK(new_result->result) &&
            sv_derived_from(new_result->result, PROMISE_CLASS)) {
            /* This is expected: our conversion function returned us one of our own promises */
            IV tmp = SvIV((SV*)SvRV(new_result->result));
            PROMISE_CLASS_TYPE* new_promise = INT2PTR(PROMISE_CLASS_TYPE*, tmp);

            xspr_promise_t* promise = new_promise->promise;
            xspr_promise_incref(aTHX_ promise);

            xspr_result_decref(aTHX_ new_result);
            return promise;

        } else {
            xspr_promise_t* promise = xspr_promise_new(aTHX);
            xspr_promise_finish(aTHX_ promise, new_result);
            xspr_result_decref(aTHX_ new_result);
            return promise;
        }
    }

    /* We didn't get a promise. */
    return NULL;
}

DEFERRED_CLASS_TYPE* _get_deferred_from_sv(pTHX_ SV *self_sv) {
    SV *referent = SvRV(self_sv);
    return INT2PTR(DEFERRED_CLASS_TYPE*, SvUV(referent));
}

PROMISE_CLASS_TYPE* _get_promise_from_sv(pTHX_ SV *self_sv) {
    SV *referent = SvRV(self_sv);
    return INT2PTR(PROMISE_CLASS_TYPE*, SvUV(referent));
}

SV* _ptr_to_svrv(pTHX_ void* ptr, HV* stash) {
    SV* referent = newSVuv( PTR2UV(ptr) );
    SV* retval = newRV_noinc(referent);
    sv_bless(retval, stash);

    return retval;
}

static inline xspr_promise_t* create_promise(pTHX) {
    dMY_CXT;

    xspr_promise_t* promise = xspr_promise_new(aTHX);

    SV **detect_in_stash = hv_fetchs(
        MY_CXT.pxs_base_stash,
        "DETECT_MEMORY_LEAKS",
        0
    );

    if (detect_in_stash && *detect_in_stash) {
        SV* detect_leak_perl = GvSV( (GV *) *detect_in_stash );

        promise->detect_leak_pid = SvTRUE(detect_leak_perl) ? getpid() : 0;
    }
    else {
        promise->detect_leak_pid = 0;
    }

    return promise;
}

/* Many promises are just thrown away after the final callback, no need to allocate a next promise for those */
static inline xspr_promise_t* create_next_promise_if_needed(pTHX_ SV* original, SV** stack_ptr) {
    if (GIMME_V != G_VOID) {
        PROMISE_CLASS_TYPE* next_promise;
        Newxz(next_promise, 1, PROMISE_CLASS_TYPE);

        xspr_promise_t* next = create_promise(aTHX);
        next_promise->promise = next;

        *stack_ptr = sv_newmortal();

        // This would be simpler, but let’s facilitate subclassing.
        // sv_setref_pv(*stack_ptr, PROMISE_CLASS, (void*)next_promise);

        sv_setref_pv(*stack_ptr, NULL, (void*)next_promise);
        sv_bless(*stack_ptr, SvSTASH(SvRV(original)));

        return next;
    }

    return NULL;
}

static inline void _warn_on_destroy_if_needed(pTHX_ xspr_promise_t* promise, SV* self_sv) {
    if (promise->detect_leak_pid && PXS_IS_GLOBAL_DESTRUCTION && promise->detect_leak_pid == getpid()) {
        warn( "======================================================================\nXXXXXX - %s survived until global destruction; memory leak likely!\n======================================================================\n", SvPV_nolen(self_sv) );
    }
}

//----------------------------------------------------------------------

MODULE = Promise::XS     PACKAGE = Promise::XS

BOOT:
{
    MY_CXT_INIT;
#ifdef USE_ITHREADS
    MY_CXT.owner = aTHX;
#endif
    MY_CXT.queue_head = NULL;
    MY_CXT.queue_tail = NULL;
    MY_CXT.in_flush = 0;
    MY_CXT.backend_scheduled = 0;
    MY_CXT.conversion_helper = NULL;

    MY_CXT.pxs_base_stash = gv_stashpv(BASE_CLASS, FALSE);
    MY_CXT.pxs_promise_stash = gv_stashpv(PROMISE_CLASS, FALSE);
    MY_CXT.pxs_deferred_stash = gv_stashpv(DEFERRED_CLASS, FALSE);

    MY_CXT.deferral_cr = NULL;
    MY_CXT.deferral_arg = NULL;
    MY_CXT.pxs_flush_cr = NULL;
}

# In some old thread-multi perls sv_dup_inc() wasn’t defined.

#if defined(USE_ITHREADS) && defined(sv_dup_inc)

# ithreads would seem to be a very bad idea in Promise-based code,
# but anyway ..

void
CLONE(...)
    PPCODE:

        SV* conversion_helper = NULL;
        SV* pxs_flush_cr = NULL;
        SV* deferral_cr = NULL;
        SV* deferral_arg = NULL;

        {
            dMY_CXT;

            CLONE_PARAMS params = {NULL, 0, MY_CXT.owner};

            if ( MY_CXT.conversion_helper ) {
                conversion_helper = sv_dup_inc( MY_CXT.conversion_helper, &params );
            }

            if ( MY_CXT.pxs_flush_cr ) {
                pxs_flush_cr = sv_dup_inc( MY_CXT.pxs_flush_cr, &params );
            }

            if ( MY_CXT.deferral_cr ) {
                deferral_cr = sv_dup_inc( MY_CXT.deferral_cr, &params );
            }

            if ( MY_CXT.deferral_arg ) {
                deferral_arg = sv_dup_inc( MY_CXT.deferral_arg, &params );
            }
        }

        {
            MY_CXT_CLONE;
            MY_CXT.owner = aTHX;

            // Clone SVs
            MY_CXT.conversion_helper = conversion_helper;
            MY_CXT.pxs_flush_cr = pxs_flush_cr;
            MY_CXT.deferral_cr = deferral_cr;
            MY_CXT.deferral_arg = deferral_arg;

            // Clone HVs
            MY_CXT.pxs_base_stash = gv_stashpv(BASE_CLASS, FALSE);
            MY_CXT.pxs_promise_stash = gv_stashpv(PROMISE_CLASS, FALSE);
            MY_CXT.pxs_deferred_stash = gv_stashpv(DEFERRED_CLASS, FALSE);
        }

        XSRETURN_UNDEF;

#endif /* USE_ITHREADS && defined(sv_dup_inc) */

#SV *
#resolved(...)
#    CODE:
#        xspr_result_t* result = xspr_result_new(aTHX_ XSPR_RESULT_RESOLVED, items);
#        unsigned i;
#        for (i = 0; i < items; i++) {
#            result->results[i] = newSVsv(ST(i));
#        }
#
#        xspr_promise_t* promise = create_promise(aTHX);
#        xspr_promise_finish(aTHX_ promise, result);
#        xspr_result_decref(aTHX_ result);
#    OUTPUT:
#        RETVAL

#----------------------------------------------------------------------

MODULE = Promise::XS     PACKAGE = Promise::XS::Deferred

PROTOTYPES: DISABLE

SV *
create()
    CODE:
        dMY_CXT;

        DEFERRED_CLASS_TYPE* deferred_ptr;
        Newxz(deferred_ptr, 1, DEFERRED_CLASS_TYPE);

        xspr_promise_t* promise = create_promise(aTHX);

        deferred_ptr->promise = promise;

        RETVAL = _ptr_to_svrv(aTHX_ deferred_ptr, MY_CXT.pxs_deferred_stash);
    OUTPUT:
        RETVAL

void
___set_deferral_generic(SV* cr, ...)
    CODE:
        dMY_CXT;

        cr = SvRV(cr);

        if (MY_CXT.deferral_cr) {
            SvREFCNT_dec(MY_CXT.deferral_cr);
        }

        MY_CXT.deferral_cr = cr;
        SvREFCNT_inc(MY_CXT.deferral_cr);

        if (items > 1) {
            if (MY_CXT.deferral_arg) {
                SvREFCNT_dec(MY_CXT.deferral_arg);
            }

            MY_CXT.deferral_arg = ST(1);
            SvREFCNT_inc(MY_CXT.deferral_arg);
        }

void
___flush(...)
    CODE:
        xspr_queue_flush(aTHX);

void
___set_conversion_helper(helper)
        SV* helper
    CODE:
        dMY_CXT;
        if (MY_CXT.conversion_helper != NULL)
            croak("Refusing to set a conversion helper twice");
        MY_CXT.conversion_helper = newSVsv(helper);

SV*
promise(SV* self_sv)
    CODE:
        dMY_CXT;

        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);

        PROMISE_CLASS_TYPE* promise_ptr;
        Newxz(promise_ptr, 1, PROMISE_CLASS_TYPE);
        promise_ptr->promise = self->promise;
        xspr_promise_incref(aTHX_ promise_ptr->promise);

        RETVAL = _ptr_to_svrv(aTHX_ promise_ptr, MY_CXT.pxs_promise_stash);
    OUTPUT:
        RETVAL

SV*
resolve(SV *self_sv, SV *value = NULL)
    CODE:
        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);

        if (self->promise->state != XSPR_STATE_PENDING) {
            croak("Cannot resolve deferred: not pending");
        }

        if (value == NULL) value = &PL_sv_undef;

        xspr_result_t* result = xspr_result_new(aTHX_ XSPR_RESULT_RESOLVED);
        result->result = newSVsv(value);

        xspr_promise_finish(aTHX_ self->promise, result);
        xspr_result_decref(aTHX_ result);

        if (GIMME_V == G_VOID) {
            RETVAL = NULL;
        }
        else {
            SvREFCNT_inc(self_sv);
            RETVAL = self_sv;
        }
    OUTPUT:
        RETVAL

SV*
reject(SV *self_sv, SV *value = NULL)
    CODE:
        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);

        if (self->promise->state != XSPR_STATE_PENDING) {
            croak("Cannot reject deferred: not pending");
        }

        if (value == NULL) value = &PL_sv_undef;

        xspr_result_t* result = xspr_result_new(aTHX_ XSPR_RESULT_REJECTED);
        result->result = newSVsv(value);

        xspr_promise_finish(aTHX_ self->promise, result);
        xspr_result_decref(aTHX_ result);

        if (GIMME_V == G_VOID) {
            RETVAL = NULL;
        }
        else {
            SvREFCNT_inc(self_sv);
            RETVAL = self_sv;
        }
    OUTPUT:
        RETVAL

SV*
clear_unhandled_rejection(SV *self_sv)
    CODE:
        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);
        // self->promise->unhandled_rejection = NULL;

        if (GIMME_V == G_VOID) {
            RETVAL = NULL;
        }
        else {
            SvREFCNT_inc(self_sv);
            RETVAL = self_sv;
        }
    OUTPUT:
        RETVAL

bool
is_pending(SV *self_sv)
    CODE:
        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);

        RETVAL = (self->promise->state == XSPR_STATE_PENDING);
    OUTPUT:
        RETVAL

void
DESTROY(SV *self_sv)
    CODE:
        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);
        //fprintf(stderr,"DESTROY on deferred with promise %p\n", self->promise);

        _warn_on_destroy_if_needed(aTHX_ self->promise, self_sv);

        // Don’t warn about a rejection if the deferred struct holds the
        // last reference to the promise struct and that promise struct
        // holds the last reference to the result struct.

        // fprintf(stderr, "DESTROY deferred, promise state %d\n", self->promise->state);
        if ( self->promise->state == XSPR_STATE_FINISHED ) {
        //fprintf(stderr, "deferred promise (%p) refs: %d; result (%p) refs: %d\n", self->promise, self->promise->refs, self->promise->finished.result, self->promise->finished.result->refs);
            if (self->promise->refs == 1 && self->promise->finished.result->refs == 1) {
//fprintf(stderr, "setting no-warn on result %p\n", self->promise->finished.result);
                //self->promise->finished.result->rejection_should_warn = false;
            }
        }

        xspr_promise_decref(aTHX_ self->promise);
        Safefree(self);

# ----------------------------------------------------------------------

MODULE = Promise::XS     PACKAGE = Promise::XS::Promise

PROTOTYPES: DISABLE

void
then(SV* self_sv, SV* on_resolve = NULL, SV* on_reject = NULL)
    PPCODE:
        PROMISE_CLASS_TYPE* self = _get_promise_from_sv(aTHX_ self_sv);

        xspr_promise_t* next;

        if (on_resolve == NULL) on_resolve = &PL_sv_undef;
        if (on_reject == NULL) on_reject = &PL_sv_undef;

        next = create_next_promise_if_needed(aTHX_ self_sv, &ST(0));

        xspr_callback_t* callback = xspr_callback_new_perl(aTHX_ on_resolve, on_reject, next);
        xspr_promise_then(aTHX_ self->promise, callback);

        XSRETURN(next ? 1 : 0);

void
catch(SV* self_sv, SV* on_reject)
    PPCODE:
        PROMISE_CLASS_TYPE* self = _get_promise_from_sv(aTHX_ self_sv);

        xspr_promise_t* next = create_next_promise_if_needed(aTHX_ self_sv, &ST(0));

        xspr_callback_t* callback = xspr_callback_new_perl(aTHX_ &PL_sv_undef, on_reject, next);
        xspr_promise_then(aTHX_ self->promise, callback);

        XSRETURN(next ? 1 : 0);

void
finally(SV* self_sv, SV* on_finally)
    PPCODE:
        PROMISE_CLASS_TYPE* self = _get_promise_from_sv(aTHX_ self_sv);

        xspr_promise_t* next = create_next_promise_if_needed(aTHX_ self_sv, &ST(0));
        //fprintf(stderr, "finally = %p\n", next);

        xspr_callback_t* callback = xspr_callback_new_finally(aTHX_ on_finally, next);
        xspr_promise_then(aTHX_ self->promise, callback);

        XSRETURN(next ? 1 : 0);

void
DESTROY(SV* self_sv)
    CODE:
        PROMISE_CLASS_TYPE* self = _get_promise_from_sv(aTHX_ self_sv);
        //fprintf(stderr, "reap perl promise %p\n", self->promise);

        /*
        if (self->promise->unhandled_rejection) {
            xspr_result_t* rejection = self->promise->unhandled_rejection;

            _warn_unhandled_rejection(aTHX_ rejection->result);
        }
        */

        _warn_on_destroy_if_needed(aTHX_ self->promise, self_sv);

        xspr_promise_decref(aTHX_ self->promise);
        Safefree(self);
