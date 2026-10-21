plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "io.github.whooslizi.androidviewer"
    compileSdk = 35
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "io.github.whooslizi.androidviewer"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

// Builds ../core (the Rust protocol bridge) into src/main/jniLibs with cargo-ndk.
// Needs rustup's cargo with the Android targets and cargo-ndk (see README).
val cargoBuild by tasks.registering(Exec::class) {
    val rustupCargo = File(System.getProperty("user.home"), ".cargo/bin/cargo")
    workingDir = rootProject.file("core")
    environment("ANDROID_NDK_HOME", android.ndkDirectory.absolutePath)
    commandLine(
        if (rustupCargo.exists()) rustupCargo.path else "cargo",
        "ndk", "-t", "arm64-v8a", "-t", "x86_64", "-o", file("src/main/jniLibs").path, "build", "--release",
    )
}
tasks.named("preBuild") { dependsOn(cargoBuild) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
}
