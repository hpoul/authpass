import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

final _logger = Logger('format_utils');

class FormatUtils {
  FormatUtils({
    required String locale,
  }) : _dateFormatFull = DateFormat.yMd(locale).add_Hms() {
    _logger.finer('Initialized with locale $locale');
  }

  final DateFormat _dateFormatFull;

  String formatDateFull(DateTime dateTime) =>
      _dateFormatFull.format(dateTime.toLocal());

  /// To keep things secure, like URLs we just log the first few characters.
  static String maxLength(String string, int maxLength,
      {String ellipsis = '…'}) {
    if (string.length > maxLength) {
      return '${string.substring(0, maxLength)}$ellipsis';
    }
    return string;
  }

  static String anonymizeUrl(String potentialUrl) =>
      maxLength(potentialUrl, 15);
}

/// Couple of constants which should not be translated, but I'm too
/// lazy to write NON-NLS on every usage.
/// (yes, that name should probably something be like `NonNlsConstants`
/// but I'm lazy).
class Nls {
  static const String BLANK = ''; // NON-NLS
  static const String NL = '\n'; // NON-NLS
  static const String SP = ' '; // NON-NLS
  static const String COMMA_SPACE = ', '; // NON-NLS
  static const String SLASH = '/'; // NON-NLS
  static const String STAR = '*'; // NON-NLS
}
