plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val isDiLinkCompatibilityBuild =
    providers.gradleProperty("zmusicDiLinkCompatibility").orNull == "true"
val releaseKeystorePath =
    providers.environmentVariable("ZMUSIC_ANDROID_KEYSTORE_PATH").orNull

android {
    namespace = "com.zmusic.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zmusic.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = if (isDiLinkCompatibilityBuild) 29 else flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes += setOf("**/x86/**", "**/x86_64/**")
        }
    }

    signingConfigs {
        getByName("debug") {
            if (!releaseKeystorePath.isNullOrBlank()) {
                storeFile = file(releaseKeystorePath)
                storePassword = providers.environmentVariable(
                    "ZMUSIC_ANDROID_KEYSTORE_PASSWORD",
                ).orNull
                keyAlias = providers.environmentVariable(
                    "ZMUSIC_ANDROID_KEY_ALIAS",
                ).orNull
                keyPassword = providers.environmentVariable(
                    "ZMUSIC_ANDROID_KEY_PASSWORD",
                ).orNull
            }
            enableV1Signing = true
            enableV2Signing = !isDiLinkCompatibilityBuild
        }
    }

    buildTypes {
        release {
            // CI injects the stable keystore; local builds retain the existing debug key.
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
