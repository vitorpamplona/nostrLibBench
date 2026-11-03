import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

application {
    mainClass.set("com.vitorpamplona.libbench.MainKt")
    applicationName = "libbench"
    applicationDefaultJvmArgs = listOf("-Xmx2g", "-XX:+UseG1GC", "-Dfile.encoding=UTF-8")
}

kotlin {
    jvmToolchain(21)
    compilerOptions { jvmTarget.set(JvmTarget.JVM_21) }
}

dependencyLocking { lockAllConfigurations() }

dependencies {
    implementation(libs.quartz)
    implementation(libs.nostr.sdk.jvm)
    implementation(libs.nostr4j)
    implementation(libs.nostr.java.api)
    implementation(libs.nostr.java.client)
    implementation(libs.rhodium)
    implementation(libs.kotlinx.coroutines.core)
}
