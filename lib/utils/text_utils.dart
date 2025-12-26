class TextUtils {
  static String cleanOcrText(String text) {
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceAll(RegExp(r'\b0\b'), 'O'); 
    text = text.replaceAll(RegExp(r'\bl\b'), 'I'); 
    text = text.replaceAll(RegExp(r'[|]+'), ' ');
    text = text.replaceAll(RegExp(r'\.{2,}'), '.');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  static String removeLeadingArtifacts(String text) {
    text = text.replaceAll(RegExp(r'^[Il\s\d\)\+\-]+'), '');
    text = text.replaceAll(RegExp(r'^[\d\s\)\(\]\[\{\}\+\-\*\/\|]+'), '');
    return text.trim();
  }
}