// gigos: 启用 Firefox autoconfig,加载同目录树根的 /opt/firefox/mozilla.cfg
// (firefox-bin 安装在 /opt/firefox;此 loader 在 <install>/defaults/pref/ 下被启动时读取)
pref("general.config.filename", "mozilla.cfg");
pref("general.config.obscure_value", 0);
pref("general.config.sandbox_enabled", false);
