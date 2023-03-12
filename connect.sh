#!/bin/bash

devices=($(adb devices | awk '/\s+(device|emulator)$/ {print $1}'))

declare -A deviceIP deviceName

function main()
{
    deviceNum=${#devices[@]}
    if [ $deviceNum -eq 0 ]; then
        echo "未发现安卓设备或模拟器,请确认安卓驱动是否安装或者安卓模拟器是否启动"
        return 0
    fi

    skipDevice=0
    for index in ${!devices[@]}
    do
        if [[ ${devices[$index]} =~ ":" ]]; then
            let skipDevice+=1
        else
            getDevicesIP ${devices[$index]}
            getDevicesName ${devices[$index]}

            if [ -z $deviceIP ]; then
                continue
            fi

            localIP=$(ifconfig|grep broadcast|awk -F ' ' '{print $2}')

            if [[ "${devices[@]}" =~ "$deviceIP" ]]; then
                echo "跳过已连接的设备：${deviceName}"
                continue
            elif [[ "${deviceIP:0:9}" =~ "${localIP:0:9}" ]]; then      # 待优化：根据子网掩码计算网段
                port=5555
                tips=$(lsof -i tcp:$port)
                while [ -n "$tips" ]
                do
                    echo "占用的端口：$port"
                    let port+=1
                    tips=$(lsof -i tcp:$port)
                done

                timeout 5 adb -s ${devices[$index]} tcpip $port
                sleep 1s
                timeout 5 adb connect $deviceIP:$port
            else
                echo "${deviceName}: 该设备无线网络与本机不属同一网段"
                continue
            fi
        fi
    done

    if [ $skipDevice -eq $deviceNum ]; then
        echo "未发现连接的设备,请使用USB线连接设备后操作"
        return 0
    fi
}

function getDevicesIP()
{
    local deviceId=$1

    deviceIP=$(adb -s $deviceId shell ip addr show wlan0 | grep -e wlan0$ | cut -d " " -f 6 | cut -d/ -f 1)
    if [ -z "$deviceIP" ]; then
        getDevicesName ${deviceId}
        echo "${deviceName}: 未获取到该设备的IP,请检查是否连接同网段的网络"
    fi
}

function getDevicesName()
{
    local para deviceId
    deviceId=$1
    deviceBrand=$(timeout 3 adb -s $deviceId shell getprop ro.product.brand)

    case "$deviceBrand" in
        HUAWEI)
            para="ro.config.marketing_name";;
        Redmi)
            para="ro.product.marketname";;
        vivo)
            para="ro.vivo.market.name";;
        OPPO)
            para="ro.vendor.oplus.market.name";;
        OnePlus)
            para="ro.product.device";;
        *)
            para="ro.product.model";;
    esac

    deviceName=$(timeout 3 adb -s $deviceId shell getprop $para)
}

main

exit 0