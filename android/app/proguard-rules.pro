# The OCR plugin compiles against optional recognizers. Learning Planet
# bundles and uses the Chinese recognizer. These six options belong to
# the three scripts whose runtime models the app does not include.
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder

# ML Kit's manifest names these registrars. Firebase ComponentDiscovery
# constructs each one through getDeclaredConstructor().newInstance().
-keepclassmembers class com.google.mlkit.common.internal.CommonComponentRegistrar { public <init>(); }
-keepclassmembers class com.google.mlkit.vision.common.internal.VisionCommonRegistrar { public <init>(); }
-keepclassmembers class com.google.mlkit.vision.text.internal.TextRegistrar { public <init>(); }
