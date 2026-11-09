package org.shelfarr.app.reader.pages

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import java.io.ByteArrayOutputStream

/** Original page art for render tests: a coloured band, a page number and lines of "text". */
object PageFixtures {
    private val colors = intArrayOf(0xFFB23A1E.toInt(), 0xFF1E5AB2.toInt(), 0xFF2E8B57.toInt(), 0xFF8E44AD.toInt())

    fun color(index: Int): Int = colors[index % colors.size]

    fun draw(index: Int, width: Int, height: Int, pageWidth: Int = 612, pageHeight: Int = 792): Bitmap {
        val (w, h) = fit(pageWidth, pageHeight, width, height)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = color(index)
        canvas.drawRect(0f, 0f, w.toFloat(), h * 0.18f, paint)
        paint.color = Color.WHITE
        paint.textSize = h * 0.07f
        canvas.drawText("Page ${index + 1}", w * 0.08f, h * 0.12f, paint)
        paint.color = 0xFF444444.toInt()
        for (line in 0 until 18) {
            val y = h * (0.26f + line * 0.038f)
            canvas.drawRect(w * 0.08f, y, w * (if (line % 5 == 4) 0.55f else 0.92f), y + h * 0.012f, paint)
        }
        return bitmap
    }

    fun png(index: Int, width: Int = 600, height: Int = 900): ByteArray {
        val bitmap = draw(index, width, height, width, height)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    fun jpeg(index: Int, width: Int = 600, height: Int = 900): ByteArray {
        val bitmap = draw(index, width, height, width, height)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
    }
}
