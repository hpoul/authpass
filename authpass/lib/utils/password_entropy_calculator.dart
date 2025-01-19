import 'dart:math';

class PasswordEntropyCalculator {
  // entropy = passLength * log2(charSetSizd)
  static double calculate({
    required int passwordLength,
    required int charSetSize,
  }) {
    double logBase(num x, num base) => log(x) / log(base);
    return passwordLength * logBase(charSetSize, 2);
  }
}
