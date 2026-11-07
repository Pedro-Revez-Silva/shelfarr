package org.shelfarr.app.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Small named secrets, unreadable outside this app and this device. */
interface SecureStore {
    fun read(name: String): String?
    fun write(name: String, value: String)
    fun delete(name: String)
}

/**
 * AES-256-GCM with a non-exportable Android Keystore key. Ciphertext lives in
 * `noBackupFilesDir`, so it never reaches device backups or transfers either.
 */
class KeystoreSecureStore(context: Context) : SecureStore {
    private val directory = File(context.noBackupFilesDir, "secure").apply { mkdirs() }

    private fun file(name: String): File {
        require(name.matches(SAFE_NAME)) { "Invalid secret name" }
        return File(directory, "$name.bin")
    }

    @Synchronized
    override fun read(name: String): String? {
        val file = file(name)
        if (!file.exists()) return null
        return try {
            val buffer = ByteBuffer.wrap(file.readBytes())
            val iv = ByteArray(buffer.get().toInt() and 0xFF).also(buffer::get)
            val ciphertext = ByteArray(buffer.remaining()).also(buffer::get)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: java.security.GeneralSecurityException) {
            // The key was invalidated or the file is damaged: treat as signed out.
            file.delete()
            null
        } catch (_: java.nio.BufferUnderflowException) {
            file.delete()
            null
        }
    }

    @Synchronized
    override fun write(name: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val temporary = File(directory, "$name.tmp")
        temporary.writeBytes(
            ByteBuffer.allocate(1 + iv.size + ciphertext.size)
                .put(iv.size.toByte())
                .put(iv)
                .put(ciphertext)
                .array(),
        )
        check(temporary.renameTo(file(name))) { "Could not save secret" }
    }

    @Synchronized
    override fun delete(name: String) {
        file(name).delete()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "shelfarr.session.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
        val SAFE_NAME = Regex("[a-z_]+")
    }
}
