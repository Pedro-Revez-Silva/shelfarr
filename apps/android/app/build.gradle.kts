import java.net.URI
import java.net.URISyntaxException
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
}

// Comma-separated hosts that a debug build may reach over plain HTTP, on top of
// the emulator and loopback defaults. Release builds never permit cleartext.
val devHttpHosts: List<String> = (findProperty("shelfarrDevHttpHosts") as String?)
    .orEmpty()
    .split(',')
    .map(String::trim)
    .filter(String::isNotEmpty)

// Build-time version. Direct-distribution updates only move forward, so each published
// build must use a larger shelfarrVersionCode than the one before it.
val shelfarrVersionCode: Int = (findProperty("shelfarrVersionCode") as String? ?: "2").trim().let { value ->
    val code = requireNotNull(value.toIntOrNull()) { "shelfarrVersionCode must be a whole number, not '$value'" }
    require(code in 1..2_100_000_000) { "shelfarrVersionCode must be between 1 and 2100000000, not $code" }
    code
}
val shelfarrVersionName: String = (findProperty("shelfarrVersionName") as String? ?: "0.1.1").trim().also { name ->
    require(name.matches(Regex("[0-9A-Za-z][0-9A-Za-z._+-]{0,47}"))) {
        "shelfarrVersionName must be 1-48 letters, digits, '.', '_', '+' or '-', starting with a letter or digit"
    }
}

// The publisher feed an in-app update may come from, fixed at build time. Empty (the
// default) switches the updater off and leaves out its install permission. Debug and
// release builds read separate properties, so a development feed can't reach a release.
fun updateFeedUrl(property: String): String {
    val value = (findProperty(property) as String?).orEmpty().trim()
    if (value.isEmpty()) return ""
    val uri = try {
        URI(value)
    } catch (error: URISyntaxException) {
        throw IllegalArgumentException("$property is not a URL", error)
    }
    require(uri.scheme == "https" && !uri.host.isNullOrEmpty()) { "$property must be an https:// URL" }
    require(uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null) {
        "$property must not carry credentials, a query or a fragment"
    }
    val path = uri.rawPath.orEmpty()
    require(path.endsWith(".json") && path.lastIndexOf('/') > 0 && path.split('/').none { it == "." || it == ".." }) {
        "$property must name a .json feed inside a directory, such as https://example.org/downloads/android.json"
    }
    require(value.none { it == '"' || it == '\\' || it.isWhitespace() }) { "$property contains characters a URL can't" }
    return value
}
val debugUpdateFeedUrl = updateFeedUrl("shelfarrUpdateFeedUrl")
val releaseUpdateFeedUrl = updateFeedUrl("shelfarrReleaseUpdateFeedUrl")

android {
    namespace = "org.shelfarr.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "org.shelfarr.app"
        minSdk = 26
        targetSdk = 37
        versionCode = shelfarrVersionCode
        versionName = shelfarrVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testInstrumentationRunnerArguments["additionalTestOutputDir"] =
            "/sdcard/Android/media/org.shelfarr.app.debug/reader-smoke"
        buildConfigField("boolean", "ALLOW_LOCAL_HTTP", "false")
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            buildConfigField("boolean", "ALLOW_LOCAL_HTTP", "true")
            buildConfigField("String", "UPDATE_FEED_URL", "\"$debugUpdateFeedUrl\"")
            buildConfigField("String", "UPDATE_CHANNEL", "\"development\"")
        }
        release {
            buildConfigField("String", "UPDATE_FEED_URL", "\"$releaseUpdateFeedUrl\"")
            buildConfigField("String", "UPDATE_CHANNEL", "\"release\"")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    // One copy of the brand fonts, shared with the iOS project.
    sourceSets["main"].assets.directories.add("../../design/assets")

    // The install permission and status receiver exist only in builds that have a feed.
    if (debugUpdateFeedUrl.isNotEmpty()) sourceSets["debug"].manifest.srcFile("src/updater/AndroidManifest.xml")
    if (releaseUpdateFeedUrl.isNotEmpty()) sourceSets["release"].manifest.srcFile("src/updater/AndroidManifest.xml")

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
            all {
                it.maxHeapSize = "2g"
                // Robolectric's native graphics loads fonts through file descriptors.
                it.jvmArgs("--add-opens=java.base/java.io=ALL-UNNAMED")
            }
        }
    }

    packaging {
        resources.excludes += setOf("META-INF/{AL2.0,LGPL2.1}", "META-INF/DEPENDENCIES")
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
        checkDependencies = false
        // Dependency freshness is managed deliberately in gradle/libs.versions.toml.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        optIn.add("kotlin.time.ExperimentalTime")
    }
}

// Debug-only network security config. It names individual development hosts, so
// no build ever carries a blanket cleartext permission.
abstract class GenerateDevNetworkConfig : DefaultTask() {
    @get:Input
    abstract val hosts: ListProperty<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val domains = hosts.get().joinToString("\n") { host ->
            require(host.matches(Regex("[A-Za-z0-9.:-]+"))) { "Invalid dev host: $host" }
            """        <domain includeSubdomains="false">$host</domain>"""
        }
        val file = outputDirectory.file("xml/network_security_config.xml").get().asFile
        file.parentFile.mkdirs()
        file.writeText(
            """
            |<?xml version="1.0" encoding="utf-8"?>
            |<network-security-config>
            |    <base-config cleartextTrafficPermitted="false" />
            |    <domain-config cleartextTrafficPermitted="true">
            |$domains
            |    </domain-config>
            |</network-security-config>
            |
            """.trimMargin(),
        )
    }
}

val generateDevNetworkConfig = tasks.register<GenerateDevNetworkConfig>("generateDevNetworkConfig") {
    hosts.set(listOf("localhost", "127.0.0.1", "10.0.2.2") + devHttpHosts)
}

androidComponents {
    onVariants(selector().withBuildType("debug")) { variant ->
        variant.sources.res?.addGeneratedSourceDirectory(
            generateDevNetworkConfig,
            GenerateDevNetworkConfig::outputDirectory,
        )
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.androidx.core)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.fragment)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.navigation.compose)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.datasource.okhttp)

    implementation(libs.readium.shared)
    implementation(libs.readium.streamer)
    implementation(libs.readium.navigator)

    implementation(libs.okhttp)
    implementation(libs.coil.compose)
    implementation(libs.coil.okhttp)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.okhttp.mockwebserver)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.okhttp.tls)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit)
    debugImplementation(libs.compose.ui.test.manifest)
}
