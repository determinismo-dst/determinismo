// SPDX-License-Identifier: MIT
/*
 * The JVM caches' app (tools/e2e.zig's jvm-caches): `train` runs its code once for the JDK's AOT
 * cache (train.sh), `serve` is the node (its setup said done, then idle), `drive` a driver's
 * start. Each is a JVM on the cache, the coverage agent on in the guest. In the unnamed package
 * beside the SDK's Determinismo, its class name the instrumented prefix (CacheDemo).
 */
public final class CacheDemo {
  public static void main(String[] arguments) throws InterruptedException {
    String mode = arguments.length > 0 ? arguments[0] : "drive";
    long sum = work(mode.length() * 7919L);
    if (mode.equals("serve")) {
      Determinismo.setupComplete(null);
      Thread.sleep(Long.MAX_VALUE);
    }
    System.out.println("cachedemo " + mode + " " + sum);
  }

  static long work(long seed) {
    long sum = 0;
    for (int i = 0; i < 1000; i++) {
      if ((seed + i) % 3 == 0) {
        sum += i;
      } else if ((seed + i) % 5 == 0) {
        sum -= i;
      } else {
        sum ^= i;
      }
    }
    return sum;
  }
}
