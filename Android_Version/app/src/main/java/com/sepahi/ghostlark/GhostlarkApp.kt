package com.sepahi.ghostlark

import android.app.Application
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions

class GhostlarkApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        Libbox.setup(SetupOptions().also {
            it.basePath = filesDir.path
            it.workingPath = (getExternalFilesDir(null) ?: filesDir).path
            it.tempPath = cacheDir.path
            it.fixAndroidStack = false
            it.logMaxLines = 2000
            it.appVersion = "1"
            it.appMarketingVersion = "0.1.0"
        })
    }

    companion object { lateinit var instance: GhostlarkApp }
}
