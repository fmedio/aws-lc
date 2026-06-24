# AWS-LC cross-compilation toolchain for bare-metal / RTOS riscv32
# (xpack riscv-none-elf GCC, newlib, no host OS).
#
# Usage:
#   cmake -B build-riscv32 \
#     -DCMAKE_TOOLCHAIN_FILE=util/riscv32-none-elf-toolchain.cmake \
#     -DCMAKE_BUILD_TYPE=Release
#   cmake --build build-riscv32
#
# Override the ISA/ABI to match your target if it differs from the
# toolchain default (rv32imac / ilp32):
#   -DRISCV_MARCH=rv32imac -DRISCV_MABI=ilp32

# "Generic" tells AWS-LC this is an embedded target: it skips the
# find_package(Threads) requirement and assumes a single-threaded build.
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR riscv32)
set(CMAKE_CROSSCOMPILING TRUE)

# Toolchain location and prefix.
set(RISCV_TOOLCHAIN_ROOT "/home/fmedio/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1"
    CACHE PATH "Root of the riscv-none-elf GCC toolchain")
set(RISCV_TRIPLE "riscv-none-elf")
set(RISCV_BIN "${RISCV_TOOLCHAIN_ROOT}/bin")

# Target ISA/ABI. Defaults match the toolchain's own default multilib.
set(RISCV_MARCH "rv32imac" CACHE STRING "RISC-V ISA string (-march)")
set(RISCV_MABI  "ilp32"    CACHE STRING "RISC-V ABI (-mabi)")

# Compilers and binutils.
set(CMAKE_C_COMPILER   "${RISCV_BIN}/${RISCV_TRIPLE}-gcc")
set(CMAKE_CXX_COMPILER "${RISCV_BIN}/${RISCV_TRIPLE}-g++")
set(CMAKE_ASM_COMPILER "${RISCV_BIN}/${RISCV_TRIPLE}-gcc")
set(CMAKE_AR      "${RISCV_BIN}/${RISCV_TRIPLE}-gcc-ar")
set(CMAKE_RANLIB  "${RISCV_BIN}/${RISCV_TRIPLE}-gcc-ranlib")
set(CMAKE_NM      "${RISCV_BIN}/${RISCV_TRIPLE}-gcc-nm")
set(CMAKE_OBJCOPY "${RISCV_BIN}/${RISCV_TRIPLE}-objcopy")
set(CMAKE_OBJDUMP "${RISCV_BIN}/${RISCV_TRIPLE}-objdump")
set(CMAKE_STRIP   "${RISCV_BIN}/${RISCV_TRIPLE}-strip")

# Architecture flags applied to every compile/link step.
set(RISCV_ARCH_FLAGS "-march=${RISCV_MARCH} -mabi=${RISCV_MABI}")

# newlib on riscv32 typedefs uint32_t as `unsigned long`, not `unsigned int`,
# so a handful of internal call sites trigger -Wincompatible-pointer-types
# and -Wformat, which AWS-LC promotes to errors via -Werror. -Wno-error=
# keeps the warnings visible but stops them from failing the build.
set(RISCV_WARN_FLAGS "-Wno-error=incompatible-pointer-types -Wno-error=format=")

# Bare-metal compile-time switches:
#
# OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED
#   Disable AWS-LC's threading support. The toolchain ships newlib's stub
#   <pthread.h>, which declares pthread_once_t but NOT pthread_rwlock_t, so
#   AWS-LC's default thread.h path fails to compile. The escape hatch is
#   documented in include/openssl/target.h.
#   WARNING: this makes AWS-LC globally thread-unsafe. Only use it if your
#   RTOS task model guarantees that all AWS-LC calls (including internal
#   state setup) happen from a single task, OR you provide your own
#   external locking around every entry point. PRNG state, error queues,
#   and global caches are NOT protected without this.
#
# OPENSSL_NO_SOCK / OPENSSL_NO_POSIX_IO
#   Disable BIO_s_connect, BIO_s_socket, BIO_s_datagram, BIO_s_fd, and the
#   helpers in bio_addr.c. Bare-metal newlib has no <sys/socket.h>. If your
#   RTOS provides a sockets layer (lwIP etc.), you can implement BIO on top
#   of it yourself instead of using these.
#
# OPENSSL_NO_TTY
#   Disable PEM passphrase prompting via /dev/tty. Newlib ships a stub
#   <termios.h> that #includes a missing <sys/termios.h>.
#
# OPENSSL_NO_FILESYSTEM
#   Disable file/directory cert loading helpers (SSL_add_dir_cert_subjects_
#   to_stack etc.). Newlib's <dirent.h> errors out at #include time with
#   "<dirent.h> not supported".
#
# BORINGSSL_UNSAFE_DETERMINISTIC_MODE
#   Replace CRYPTO_sysrand with a fixed-seed counter. This is the only
#   entropy backend that doesn't need an OS, but it produces PREDICTABLE
#   randomness and MUST NOT be used in production. It exists to get the
#   cross-compile / link pipeline green; for real use, drop this flag and
#   provide your own CRYPTO_sysrand backed by a hardware TRNG or RTOS RNG.
set(RISCV_DEFINES
    "-DOPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED"
    "-DOPENSSL_NO_SOCK"
    "-DOPENSSL_NO_POSIX_IO"
    "-DOPENSSL_NO_TTY"
    "-DOPENSSL_NO_FILESYSTEM"
    "-DBORINGSSL_UNSAFE_DETERMINISTIC_MODE")
string(REPLACE ";" " " RISCV_DEFINES "${RISCV_DEFINES}")

set(CMAKE_C_FLAGS_INIT   "${RISCV_ARCH_FLAGS} ${RISCV_WARN_FLAGS} ${RISCV_DEFINES} -ffunction-sections -fdata-sections")
# In C++ the uint32_t/unsigned mismatch is a hard error, not a warning;
# -fpermissive downgrades it to a warning. AWS-LC then upgrades that
# warning back to an error via its global -Werror, which we override by
# putting -Wno-error in the *_RELEASE flag set (appended after
# CMAKE_CXX_FLAGS by CMake, so it takes precedence).
set(CMAKE_CXX_FLAGS_INIT "${RISCV_ARCH_FLAGS} ${RISCV_WARN_FLAGS} ${RISCV_DEFINES} -fpermissive -ffunction-sections -fdata-sections")
set(CMAKE_ASM_FLAGS_INIT "${RISCV_ARCH_FLAGS}")
set(CMAKE_C_FLAGS_RELEASE_INIT   "-O3 -DNDEBUG -Wno-error")
set(CMAKE_CXX_FLAGS_RELEASE_INIT "-O3 -DNDEBUG -Wno-error")

# We can't run target binaries on the host, so force the compiler check to
# build a static library instead of a test executable (no startup/linker
# script available at configure time).
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Look on the host only for programs; everything else comes from the sysroot.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
