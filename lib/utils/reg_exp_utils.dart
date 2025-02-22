final mentionRegExp = RegExp(r'@(\S*)$');
final mentionNumberRegExp = RegExp(r'@(\d{4,})');
final uriRegExp = RegExp(r'[a-zA-z]+://[^\s].*?((?=["\s，）)(（。：])|$)');
final botNumberStartRegExp = RegExp(r'(?<=^\s*@)700\d{6}(?=$|\D)');
final botNumberRegExp = RegExp(r'(?<=^|\D)7000\d{6}(?=$|\D)');
