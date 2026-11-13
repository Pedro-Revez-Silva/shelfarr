package org.shelfarr.app.update

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.io.File
import java.security.MessageDigest

/** What identifies an app build: package, version and the certificates that signed it. */
data class AppIdentity(
    val packageName: String,
    val versionCode: Long,
    val versionName: String?,
    /** Lowercase hex SHA-256 of each current signing certificate. */
    val signers: Set<String>,
    val minSdk: Int? = null,
)

/** Reads identities from Android. Tests supply their own. */
interface PackageInspector {
    /** This installed app. */
    fun installed(): AppIdentity

    /** An APK file on disk, or null if Android can't read it as a package. */
    fun archive(file: File): AppIdentity?
}

/**
 * Asks PackageManager. These checks come before Android's installer, which still
 * verifies every APK signature itself and remains the authority; they only stop a
 * file that is plainly not the announced update from reaching it.
 */
class AndroidPackageInspector(private val context: Context) : PackageInspector {
    private val packages: PackageManager get() = context.packageManager

    override fun installed(): AppIdentity {
        val info = packageInfo { flags -> packages.getPackageInfo(context.packageName, flags) }
            ?: error("The installed package is unreadable")
        return identity(info) ?: error("The installed package has no signing certificate")
    }

    override fun archive(file: File): AppIdentity? {
        val info = packageInfo { flags -> packages.getPackageArchiveInfo(file.path, flags) } ?: return null
        // Before API 28 the archive's signatures are read relative to these paths.
        info.applicationInfo?.apply {
            sourceDir = file.path
            publicSourceDir = file.path
        }
        return identity(info)
    }

    @Suppress("DEPRECATION")
    @SuppressLint("PackageManagerGetSignatures")
    private fun packageInfo(read: (Int) -> PackageInfo?): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            // Before API 28 this is the only signer list. Every signer is compared, so
            // the multiple-signer weakness this lint warns about doesn't apply here.
            PackageManager.GET_SIGNATURES
        }
        return try {
            read(flags)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun identity(info: PackageInfo): AppIdentity? {
        val signatures: Array<Signature>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // The current signers only, not a rotation history: an update must be signed
            // exactly as the installed app is.
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        val signers = signatures.orEmpty().map { digest(it.toByteArray()) }.toSet()
        if (signers.isEmpty()) return null
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        return AppIdentity(
            packageName = info.packageName,
            versionCode = versionCode,
            versionName = info.versionName,
            signers = signers,
            minSdk = info.applicationInfo?.minSdkVersion,
        )
    }

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
}
