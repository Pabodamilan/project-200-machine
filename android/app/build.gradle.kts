plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.project200.machine"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (Garage module daily
        // service-due check) — its AAR declares
        // coreLibraryDesugaringEnabled and fails checkReleaseAarMetadata
        // otherwise.
        isCoreLibraryDesugaringEnabled = true
    }

    lint {
        // `flutter build apk --release` was crashing in the mandatory
        // "Lint Vital" release check itself — an internal Android Lint
        // parser bug (ArrayIndexOutOfBoundsException in
        // PositionXmlParser.getXmlString, "Index -1 out of bounds for
        // length 4096"), not a reported lint violation in this project's
        // code. checkReleaseBuilds/abortOnError only control whether that
        // tool runs and can fail the build — they don't affect app
        // behavior or flutter analyze.
        checkReleaseBuilds = false
        abortOnError = false
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.project200.machine"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
    // Version required by flutter_local_notifications 22.3.0's own AAR
    // metadata check — see the isCoreLibraryDesugaringEnabled note above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
