import java.util.Properties
import java.io.FileInputStream


plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.twentyonevision.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "dev.twentyonevision.app"
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Fallback for the "profile" build type, which Flutter adds
        // automatically and doesn't get its own override below.
        buildConfigField("String", "MODEL_BASE_URL", "\"http://10.0.2.2:8000\"")
    }
    signingConfigs {
        create("release") {
            val keystorePropertiesFile = rootProject.file("key.properties")
            val keystoreProperties = Properties().apply {
                load(FileInputStream(keystorePropertiesFile))
            }

            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
        }
    }


    buildTypes {
        debug {
            // model_host/serve.py - run `adb reverse tcp:8000 tcp:8000` first.
            buildConfigField("String", "MODEL_BASE_URL", "\"http://127.0.0.1:8000\"")
        }
        release {
            signingConfig = signingConfigs.getByName("release")

            isMinifyEnabled = false
            isShrinkResources = false

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                file("proguard-rules.pro")
            )

            // Matches the "models-v1" GitHub Release tag - see model_host/README.md.
            buildConfigField(
                "String",
                "MODEL_BASE_URL",
                "\"https://github.com/Raseelp/Vector-LocalSemanticSearch/releases/download/models-v1\""
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.pytorch:pytorch_android:1.13.1")
    implementation("org.pytorch:pytorch_android_torchvision:1.13.1")
    implementation("com.facebook.soloader:soloader:0.10.5")
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("androidx.work:work-runtime-ktx:2.11.2")

    // Needed for R8 to resolve SoLoader's annotations
    compileOnly("javax.annotation:javax.annotation-api:1.3.2")
}
