package app.alextran.immich.connectivity

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager

class ConnectivityApiImpl(context: Context) : ConnectivityApi {
  private val appContext = context.applicationContext
  private val connectivityManager =
    context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
  private val wifiManager =
    context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

  override fun getCapabilities(): List<NetworkCapability> {
    val capabilities = connectivityManager.getNetworkCapabilities(connectivityManager.activeNetwork)
      ?: return emptyList()

    val hasWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
      capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
    val hasCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
    val hasVpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    val isUnmetered = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)

    return buildList {
      if (hasWifi) add(NetworkCapability.WIFI)
      if (hasCellular) add(NetworkCapability.CELLULAR)
      if (hasVpn) {
        add(NetworkCapability.VPN)
        if (!hasWifi && !hasCellular) {
          if (wifiManager.isWifiEnabled) add(NetworkCapability.WIFI)
          // If VPN is active, but neither WIFI nor CELLULAR is reported as active,
          // assume CELLULAR if WIFI is not enabled
          else add(NetworkCapability.CELLULAR)
        }
      }
      if (isUnmetered) add(NetworkCapability.UNMETERED)
    }
  }

  override fun getBatteryStatus(): BatteryStatus {
    val intent: Intent? = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
    val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
    val percent = if (level >= 0 && scale > 0) (level * 100) / scale else -1
    val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
    val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
    val charging = plugged != 0 ||
      status == BatteryManager.BATTERY_STATUS_CHARGING ||
      status == BatteryManager.BATTERY_STATUS_FULL
    return BatteryStatus(percent.toLong(), charging)
  }
}
