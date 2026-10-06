define Device/hinlink_ht2
  $(Device/rk3528)
  DEVICE_VENDOR := HINLINK
  DEVICE_MODEL := HT2
  DEVICE_DTS := rk3528-hinlink-ht2
  UBOOT_DEVICE_NAME := hinlink-ht2-rk3528
  # 两个无线驱动都装上，选哪个由芯片自己决定。
  #
  # HT2 至少有两个批次：厂商 DTS 写的是 wifi_chip_type = "ap6275s"
  # （AMPAK 模块，芯片是 Broadcom BCM43752），而 leux 那篇 iStoreOS 教程里
  # 移植的是 AIC8800D80。两者在设备树上是**同一套接线** —— 都挂 &sdio0、
  # 共用同一个复位脚（GPIO1_A6），所以 DTS 不用改，差别只在驱动与固件。
  #
  # 都编进去之后，开机 dmesg 里谁认到就是谁，不需要用户先拆机确认。
  # 代价是几 MB 的固件体积，对一个 8GB eMMC 的机器可以忽略。
  DEVICE_PACKAGES := kmod-brcmfmac brcmfmac-firmware-43752-sdio \
	brcmfmac-nvram-43752-sdio \
	kmod-aic8800-sdio aic8800-sdio-firmware \
	wpad-openssl
endef
TARGET_DEVICES += hinlink_ht2
