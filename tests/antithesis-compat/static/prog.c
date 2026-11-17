// SPDX-License-Identifier: MIT
// A static program without libc, as a Zig program with its own _start is (TigerBeetle's): no C
// runtime, so no constructor runs, the trace-pc-guard one included. libvoidstar
// (lib/libvoidstar.o) numbers its guards at their first call instead, and reports its edges as
// source lines. It supplies what libvoidstar takes from a program: memcpy, memset, getauxval.
typedef unsigned long size_t;

__attribute__((no_sanitize("coverage"))) void *memcpy(void *to, const void *from, size_t n) {
    char *a = to;
    const char *b = from;
    while (n--) *a++ = *b++;
    return to;
}

__attribute__((no_sanitize("coverage"))) void *memset(void *to, int c, size_t n) {
    char *a = to;
    while (n--) *a++ = (char)c;
    return to;
}

// No auxiliary vector read: libvoidstar's callers then take the system call path.
__attribute__((no_sanitize("coverage"))) unsigned long getauxval(unsigned long type) {
    (void)type;
    return 0;
}

static long system_call3(long number, long a, long b, long c) {
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(number), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return result;
}

static int step(int x) {
    if (x % 3 == 0) return x / 3;
    if (x % 5 == 0) return x * 2;
    return x + 1;
}

int main(void) {
    int total = 0;
    for (int i = 0; i < 1000; i++) total += step(i);
    static const char said[] = "static-prog ran\n";
    system_call3(1, 1, (long)said, sizeof said - 1); // write
    return total == 0;
}

__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile(
        "xor %rbp, %rbp\n"
        "and $-16, %rsp\n"
        "call main\n"
        "mov %eax, %edi\n"
        "mov $60, %eax\n" // exit
        "syscall\n");
}
