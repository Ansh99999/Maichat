plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Base64
import java.util.Properties
import java.io.FileInputStream

// MaiChat Beta is the same code built as a second app that installs beside
// MaiChat (its own package, label and data). The one switch is the Dart define
// `MAICHAT_BETA=true`, read here out of the `dart-defines` property Flutter
// hands Gradle (comma-separated, each base64 "KEY=VALUE"), so the Dart side
// (`kIsBeta`) and the Android identity can never disagree.
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.mapNotNull { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull()
        }
        ?.mapNotNull { pair ->
            val parts = pair.split("=", limit = 2)
            if (parts.size == 2) parts[0] to parts[1] else null
        }
        ?.toMap()
        ?: emptyMap()
val isBeta = dartDefines["MAICHAT_BETA"] == "true"

// Release signing pulled from android/key.properties, which is not committed.
// Falls back to unsigned (debug) if the file is missing, so a fresh checkout
// still builds.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "me.maitavern.maichat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The namespace (and so the Kotlin package of MainActivity) stays put;
        // only the installed identity changes for the beta.
        applicationId = if (isBeta) "me.maitavern.maichat.beta" else "me.maitavern.maichat"
        manifestPlaceholders["appLabel"] = if (isBeta) "MaiChat Beta" else "MaiChat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release key when key.properties is present;
            // otherwise fall back to debug so `flutter run --release` still works.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        getByName("profile") {
            // Sign the profile build the same way as release, so a profiling
            // build installs in place over an existing install (no uninstall, no
            // lost chats) when profiling on a real device.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
