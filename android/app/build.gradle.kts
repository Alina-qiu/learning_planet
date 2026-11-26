import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val dartValues = (project.findProperty("dart-defines") as? String).orEmpty().split(",")
    .filter { it.isNotEmpty() }.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
val measureStartup = dartValues.firstOrNull { it.startsWith("MEASURE_STARTUP=") }?.substringAfter("=") ?: "false"
// Explicit test build only; ordinary debug/release APKs exclude this source set.
val legacyAnrFixture = providers.gradleProperty("legacyAnrFixture").orNull == "true"
val exitHistoryFixture = providers.gradleProperty("exitHistoryFixture").orNull == "true"
val localBackend = dartValues.any { it == "LOCAL_BACKEND=true" }
require(listOf(legacyAnrFixture, exitHistoryFixture, localBackend).count { it } <= 1) {
    "Local backend and native fixture builds must be separate"
}
require(!exitHistoryFixture || gradle.startParameter.taskNames.none {
    it.contains("release", ignoreCase = true) || it.contains("profile", ignoreCase = true)
}) { "Exit history fixture is only supported by debug builds" }
require(!localBackend || gradle.startParameter.taskNames.none {
    it.contains("release", ignoreCase = true) || it.contains("profile", ignoreCase = true)
}) { "LOCAL_BACKEND is only supported by debug builds" }
require(measureStartup in setOf("true", "false")) { "MEASURE_STARTUP must be true or false" }

android {
    namespace = "com.learningplanet.learning_planet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    buildFeatures { buildConfig = true }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = when {
            legacyAnrFixture -> "com.learningplanet.learning_planet.anrfixture"
            exitHistoryFixture -> "com.learningplanet.learning_planet.exitfixture"
            else -> "com.learningplanet.learning_planet"
        }
        buildConfigField("boolean", "MEASURE_STARTUP", measureStartup)
        manifestPlaceholders["appLabel"] = if (localBackend) "学习星球·本机" else "学习星球"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            if (localBackend) applicationIdSuffix = ".local"
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    if (legacyAnrFixture) {
        sourceSets.getByName("main") {
            java.srcDir("src/anrFixture/kotlin")
            manifest.srcFile("src/anrFixture/AndroidManifest.xml")
        }
    }
    if (exitHistoryFixture) {
        sourceSets.getByName("main") {
            java.srcDir("src/exitFixture/kotlin")
            manifest.srcFile("src/exitFixture/AndroidManifest.xml")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
