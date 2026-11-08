import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.swift.clip"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.swift.clip"
        minSdk = 26
        targetSdk = 35
        versionCode = 6
        versionName = "0.3.0"
    }

    // Signing details live in android/keystore.properties, which is never
    // committed. Without it the release build is unsigned and cannot install.
    val signingFile = rootProject.file("keystore.properties")
    val signing = Properties().apply {
        if (signingFile.exists()) signingFile.inputStream().use { load(it) }
    }
    signingConfigs {
        if (signingFile.exists()) {
            create("release") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (signingFile.exists()) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("com.google.zxing:core:3.5.3")
    testImplementation("junit:junit:4.13.2")
}
