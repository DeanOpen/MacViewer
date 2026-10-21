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
        minSdk = 29
        targetSdk = 35
        // CI passes the run number and tag; local builds stay at 1 / 0.1.0.
        versionCode = System.getenv("ANDROID_VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("ANDROID_VERSION_NAME") ?: "0.1.0"
    }

    // Release signing comes from the environment (GitHub secrets in CI, see README).
    // Without it, release builds fall back to the debug key so they still install.
    val keystore = System.getenv("ANDROID_KEYSTORE_FILE")?.let(::file)?.takeIf { it.exists() }
    signingConfigs {
        if (keystore != null) create("release") {
            storeFile = keystore
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
// Inputs and outputs let Gradle skip it, and the repackaging after it, when nothing changed.
val cargoBuild by tasks.registering(Exec::class) {
    val rustupCargo = File(System.getProperty("user.home"), ".cargo/bin/cargo")
    val linuxViewer = rootProject.file("../LinuxViewer")
    inputs.files(fileTree("${rootProject.projectDir}/core/src"), rootProject.files("core/Cargo.toml", "core/Cargo.lock"))
    inputs.files(fileTree("$linuxViewer/src"), fileTree("$linuxViewer/assets"), files("$linuxViewer/Cargo.toml"))
    outputs.dir("src/main/jniLibs")
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
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    testImplementation("junit:junit:4.13.2")
}
