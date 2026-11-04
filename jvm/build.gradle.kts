import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

application {
    mainClass.set("com.vitorpamplona.libbench.MainKt")
    applicationName = "libbench"
    // The parent process forks one child JVM per client with these same arguments (see
    // Main.kt), so every library gets the same heap and collector.
    // - The heap Amethyst Desktop runs with: -Xmx2g, no -Xms, so G1 sizes and grows it the
    //   way it does in an app.
    // - G1 explicitly: the desktop default on any machine with 2+ cores and 2 GB, but the JVM
    //   falls back to Serial on small containers.
    // (The same flags as nostrJsonBench's JVM harness.)
    applicationDefaultJvmArgs = listOf("-Xmx2g", "-XX:+UseG1GC", "-Dfile.encoding=UTF-8")
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(JvmTarget.JVM_21) }
}

// gradle.lockfile pins every resolved version, transitive ones included:
// ./gradlew dependencies --write-locks after changing a version in libs.versions.toml.
// A local Quartz (-PquartzDir) is a project, not a locked module: locking is off for that build.
val quartzDir: String? = providers.gradleProperty("quartzDir").orNull
if (quartzDir == null) dependencyLocking { lockAllConfigurations() }

dependencies {
    implementation(libs.quartz)
    implementation(libs.nostr.sdk.jvm)
    implementation(libs.nostr4j)
    implementation(libs.nge.platform.jvm)
    implementation(libs.nostr.java.api)
    implementation(libs.nostr.java.client)
    implementation(libs.rhodium)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.websockets)
}

// The Quartz under test when built with -PquartzDir: "local <dir>@<commit>".
val localQuartz: String? =
    quartzDir?.let { dir ->
        val commit =
            providers
                .exec {
                    commandLine("git", "-C", dir, "rev-parse", "--short", "HEAD")
                    isIgnoreExitValue = true
                }.standardOutput.asText
                .get()
                .trim()
        "local ${File(dir).canonicalFile.name}@${commit.ifEmpty { "unknown" }}"
    }

// The version of every module on the runtime classpath, as resolved (and locked), written
// into a resource the harness reports in each row.
val generatedResources = layout.buildDirectory.dir("generated/libbench-resources")
val resolvedModules: Provider<List<String>> =
    configurations.runtimeClasspath.map { cfg ->
        cfg.incoming.resolutionResult.allComponents
            .mapNotNull { it.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier }
            .map { "${it.group}\\:${it.module}=${it.version}" }
            .plus(listOfNotNull(localQuartz?.let { "com.vitorpamplona.quartz\\:quartz-jvm=$it" }))
            .sorted()
    }
val writeLibraryVersions by tasks.registering {
    val out = generatedResources.map { it.file("libbench-versions.properties") }
    val lines = resolvedModules
    inputs.property("modules", lines)
    outputs.file(out)
    doLast {
        out.get().asFile.apply {
            parentFile.mkdirs()
            writeText(lines.get().joinToString("\n", postfix = "\n"))
        }
    }
}
sourceSets.main {
    resources.srcDir(writeLibraryVersions.map { generatedResources.get() })
}
