// Copyright Amazon.com Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0 OR ISC

#include <openssl/rand.h>

#include "internal.h"

#if defined(OPENSSL_RAND_JITTER)

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "../../third_party/jitterentropy/jitterentropy-library/jitterentropy.h"

// Bare-metal CRYPTO_sysrand backed by the jitter-entropy library, used on
// targets that have neither /dev/urandom, getentropy(), nor a hardware
// TRNG. The CPU cycle counter (rdcycle / cycleh) supplies the timer that
// jitterentropy needs to measure micro-architectural noise.
//
// We allocate the entropy collector lazily on first use and keep it for
// the life of the program. There is no destructor: aws-lc's CRYPTO_sysrand
// contract is "must not fail," and reseeding a fresh collector on every
// call would be far too slow (~100ms+ per init on a soft-arithmetic core).
//
// THREAD SAFETY: this is intentionally single-threaded. AWS-LC is built
// for this target with OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_
// IF_THREADED, which means the entire library must be called from a
// single execution context.

static struct rand_data *g_jent_ctx = NULL;

static void jitter_init_or_abort(void) {
  if (g_jent_ctx != NULL) {
    return;
  }

  // jent_entropy_init runs SP 800-90B start-up health tests on the timer.
  // Non-zero return means the timer is broken or too coarse for entropy
  // collection. There is no safe fallback at this point, so abort.
  if (jent_entropy_init() != 0) {
    abort();
  }

  // osr=1 is the default oversampling rate. Flags=0 means no special
  // modes (no forced FIPS, no internal-timer thread, no AES conditioner).
  g_jent_ctx = jent_entropy_collector_alloc(1, 0);
  if (g_jent_ctx == NULL) {
    abort();
  }
}

void CRYPTO_sysrand(uint8_t *out, size_t requested) {
  jitter_init_or_abort();

  while (requested > 0) {
    // jent_read_entropy_safe drains health-test failures by reallocating
    // the collector internally and retrying. Returns bytes produced, or
    // a negative value on hard failure.
    ssize_t n = jent_read_entropy_safe(&g_jent_ctx, (char *)out, requested);
    if (n <= 0) {
      abort();
    }
    out += (size_t)n;
    requested -= (size_t)n;
  }
}

#endif  // OPENSSL_RAND_JITTER
