#!/bin/bash

# 健壮性测试报告邮件发送开关, true：发送邮件, false：不发送邮件
isSendReport="true"

# 健壮性测试报告的收件人, 多个收件人之间以空格间隔
mailTo="zhoujd@onecloud.cn"

# 健壮性测试报告的抄送人, 多个抄送人之间以空格间隔
#mailCc=""

# 健壮性测试报告的暗送人, 多个暗送人之间以空格间隔
#mailBcc=""

# 健壮性测试报告的邮件主题
mailSubject="健壮性测试报告"

# 在测试手机上匹配的包名前缀
packagePrefix="onecloud.cn."

# Monkey随机事件间隔时间，建议500-800,单位ms
throttle=500

## 执行过后会生成.MONKEY文件夹
MONKEY_HOME=$HOME/.MONKEY
MD5="7af8e3a71ca5ff531b85370e2ffc23d4"
## 框架路径-例：/home/clouder/monkey
SCRIPT_HOME=$(cd $(dirname ${BASH_SOURCE[0]});pwd)
## 执行脚本路径-例：/home/clouder/monkey/monkey.sh
SCRIPT_FILE=$SCRIPT_HOME/$(basename ${BASH_SOURCE[0]})
## 报告路径-例：/home/clouder/monkey/result
RESULT_HOME=$SCRIPT_HOME/result

arrResult=()
arrRunDevice=()
arrSkipDevice=()
arrSelectedDevice=()
declare -A dicReportImg dicDeviceIndex dicDeviceBrand dicDeviceModel dicDeviceAndroid dicAppLable dicAppVersion dicDevices dicMonkeyJob dicDeviceTemp1

function main()
{
    if [ $# -eq 0 ]; then
        arrApkPath=($(ls $SCRIPT_HOME/*.apk 2>&-))
    else
        arrApkPath=($@)
    fi

    checkEnvironment
    verifyApk
    scanDevices

    apkNum=${#arrApkPath[@]}

    if [ $apkNum -ne 0 ]; then
        installApk
    fi

    if [ $apkNum -eq 0 ]; then
        if [ ${#arrSelectedDevice[*]} -eq 1 ]; then
            findApp
        else
            findAppInMultiDevice
        fi
    fi

    setRunMinutes
    runDeviceNum=${#arrRunDevice[*]}

    mkdir -p $RESULT_HOME
    RESULT_PATH="$RESULT_HOME/$packageName"
    ERROR_LOG_PATH="$RESULT_PATH/error"

    passStyle="color: green"
    failStyle="color: red"
    highlightStyle="color: red; background: pink"
    overlongStyle="word-break: break-all; word-wrap: break-word"

    cd $RESULT_HOME

    if [ -d "$packageName" ]; then
        local id=$(ls -d ${packageName}-* 2>&- | grep -Pos "(?<=${packageName}-)\d+$" | sort -nr | head -1)
        id=${id:-0}
        id=$((id+1))
        mv $packageName ${packageName}-$id
    fi

    if [ $runDeviceNum -eq 1 ]; then
        deviceId=${arrSelectedDevice[0]}
        runMonkey $deviceId $packageName    # 如不从arrSelectedDevice重新取值，则会复用scanDevices方法遍历的最后一个deviceId
    else
        anrTotal=0
        crashTotal=0
        passDeviceNum=0
        failDeviceNum=0
        abnormalDeviceNum=0
        skipDeviceNum=${#arrSkipDevice[*]}

        if [ $skipDeviceNum -gt 0 ]; then
            tips yellow "由于未安装 $packageName, 跳过以下 $skipDeviceNum 台设备:"

            for index in ${!arrSkipDevice[*]}
            do
                deviceId=${arrSkipDevice[$index]}
                tips red "${dicModels[$deviceId]} ($deviceId)"
            done
        fi

        if [ $apkNum -gt 0 ]; then
            appVersionInfo="<h3>应用版本: ${appVersion}</h3>\n"
        else
            appLabel=${dicAppLable[${arrRunDevice[0]}]}
        fi

        begin=$(date +'%Y-%m-%d %H:%M:%S')

        for index in ${!arrRunDevice[*]}
        do
            deviceId=${arrRunDevice[$index]}
            appPath=$(timeout 3 adb -s $deviceId shell pm path $packageName | grep -Pos '(?<=package:).*')
            appLabel=$(timeout 3 adb -s $deviceId shell /data/local/tmp/aapt d badging $appPath | grep -Pos "(?<=application-label:').*?(?=')")
            appVersion=$(timeout 3 adb -s $deviceId shell /data/local/tmp/aapt d badging $appPath | grep -Pos "(?<=versionName\=').*?(?=')")
            dicAppVersion[$deviceId]="${appVersion%??????????}"
            dicAppLable[$deviceId]="$appLabel"
            dicDeviceIndex[$deviceId]=$((index+1))
            runMonkey $deviceId $packageName &
            dicMonkeyJob[$deviceId]=$!
        done

        for deviceId in ${!dicMonkeyJob[*]}
        do
            wait ${dicMonkeyJob[$deviceId]} 2>&-
            ret=$?

            if [ $ret -eq 0 ]; then
                testResult="通过"
                passDeviceNum=$((passDeviceNum+1))
            elif [ $ret -eq 1 ]; then
                testResult="失败"
                failDeviceNum=$((failDeviceNum+1))
            else
                testResult="异常"
                abnormalDeviceNum=$((abnormalDeviceNum+1))
            fi

            deviceIndex=${dicDeviceIndex[$deviceId]}
            report="$RESULT_PATH/device-$((deviceIndex))/report.html"
            anrCount=$(grep -m 1 -Pos '(?<=<h3>ANR次数: ).*?(?=</h3>)' $report)
            crashCount=$(grep -m 1 -Pos '(?<=<h3>Crash次数: ).*?(?=</h3>)' $report)
            coverage=$(grep -m 1 -Pos '(?<=<h3>测试覆盖率: ).*?(?=</h3>)' $report)
            deviceBattery=$(grep -m 1 -Pos '(?<=<h3>应用耗电: ).*?(?=mAh</h3>)' $report)
            deviceTemperature=$(grep -m 1 -Pos '(?<=<h3>设备温度: ).*?(?=℃</h3>)' $report)
            anrTotal=$((anrTotal+anrCount))
            crashTotal=$((crashTotal+crashCount))
            arrResult[$deviceIndex]="${dicDeviceBrand[$deviceId]},${dicDeviceModel[$deviceId]},${dicDeviceAndroid[$deviceId]},${dicAppVersion[$deviceId]},${crashCount},${anrCount},${coverage},${deviceBattery},${deviceTemperature},${testResult}"
        done

        end=$(date +'%Y-%m-%d %H:%M:%S')

        genMergeReport
    fi

    sendReport
    cd $SCRIPT_HOME
}

function checkEnvironment()
{
    if [ -d "$MONKEY_HOME" ]; then
        if [ -n "$MD5" ]; then
            cd $MONKEY_HOME
            oldMD5=$(find -type f -exec md5sum {} \; | sort -k2 | md5sum | awk '{print $1}')

            if [ "$oldMD5" != "$MD5" ]; then
                rm -rf "$MONKEY_HOME"
                extractDepends
            fi
        fi
    else
        extractDepends
    fi

    export PATH=$MONKEY_HOME:$PATH
}

function verifyApk()
{
    if [ ${#arrApkPath[@]} -eq 0 ]; then
        return 0
    fi

    for apkIndex in ${!arrApkPath[@]}
    do
        apkFile=${arrApkPath[$apkIndex]}

        if [ ! -s "$apkFile" ]; then
            tips red "$apkFile not exist or empty"
            unset arrApkPath[$apkIndex]
            continue
        fi

        if [ "${apkFile##*.}" != "apk" ]; then
            tips red "Just support .apk type"
            unset arrApkPath[$apkIndex]
            continue
        fi

        aapt d badging $apkFile &>/dev/null

        if [ $? -ne 0 ]; then
            tips red "Invalid apk: $apkFile"
            unset arrApkPath[$apkIndex]
            continue
        fi

        if [ "$(dirname $apkFile)" == "." ]; then
            apkFile="$PWD/$(basename $apkFile)"
        fi
    done
}

function extractDepends()
{
    mkdir -p $MONKEY_HOME
    DEPEND_PACK="$MONKEY_HOME/depend.tar.gz"
    sed -n -e '1,/^exit 0$/!p' $SCRIPT_FILE > $DEPEND_PACK

    if [ $? -ne 0 -o ! -s "$DEPEND_PACK" ]; then
        tips red "Failed to extract dependencies"
        exit 126
    fi

    tar zxf "$DEPEND_PACK" -C $MONKEY_HOME

    if [ $? -ne 0 ]; then
        tips red "Failed to decompress dependcies"
        exit 126
    fi

    rm -f $DEPEND_PACK &
}

function scanDevices()
{
    tips cyan "正在检测安卓设备..."
    devices=($(adb devices | awk '/\s+(device|emulator)$/ {print $1}'))
    deviceNum=${#devices[@]}

    if [ $deviceNum -eq 0 ]; then
        tips red "未发现安卓设备或模拟器,请确认安卓驱动是否安装或者安卓模拟器是否启动"
        exit 127
    fi

    if [ $deviceNum -eq 1 ]; then
        deviceId=${devices[0]}
        deviceBrand=$(timeout 3 adb -s $deviceId shell getprop ro.product.brand)
        getDevicesName $deviceBrand
        deviceModel=${deviceName#${deviceBrand}}
        androidVersion=$(timeout 3 adb -s $deviceId shell getprop ro.build.version.release)
        # 获取执行设备起始温度
        deviceTemp1=$(timeout 3 adb -s $deviceId shell dumpsys battery|grep temperature|awk -F ' ' '{print $2}')
        deviceTemp1=$(echo "scale=1;$deviceTemp1/10"|bc)
        tips cyan "发现安卓设备: $deviceBrand $deviceModel (android $androidVersion)"
        arrSelectedDevice=(${devices[*]})
        dicDeviceBrand[$deviceId]="$deviceBrand"
        dicDeviceModel[$deviceId]="$deviceModel"
        dicDeviceAndroid[$deviceId]="$androidVersion"
        dicDeviceTemp1[$deviceId]="$deviceTemp1"
    else
        tips cyan "发现 $deviceNum 个设备:"
        tips cyan "0: 选择全部设备"

        for index in ${!devices[@]}
        do
            deviceId=${devices[$index]}
            deviceBrand=$(timeout 3 adb -s $deviceId shell getprop ro.product.brand)
            getDevicesName $deviceBrand
            deviceModel=${deviceName#${deviceBrand}}
            androidVersion=$(timeout 3 adb -s $deviceId shell getprop ro.build.version.release)
            # 获取执行前设备的温度
            deviceTemp1=$(timeout 3 adb -s $deviceId shell dumpsys battery|grep temperature|awk -F ' ' '{print $2}')
            deviceTemp1=$(echo "scale=1;$deviceTemp1/10"|bc)
            tips cyan "$((index+1)): $deviceBrand $deviceModel (android $androidVersion)"
            dicDeviceBrand[$deviceId]="$deviceBrand"
            dicDeviceModel[$deviceId]="$deviceModel"
            dicDeviceAndroid[$deviceId]="$androidVersion"
            dicDeviceTemp1[$deviceId]="$deviceTemp1"
        done

        until [ "$choice" -ge 0 -a "$choice" -le $deviceNum ] 2>&-
        do
            tips -yellow "请选择设备[q:退出]: "
            read choice

            if [ "$choice" == "q" ]; then
                exit
            fi

            if [ "$choice" -ge 0 -a "$choice" -le $deviceNum ] 2>&-; then
                tips cyan "已选择: $choice"

                if [ "$choice" == "0" ]; then
                    arrSelectedDevice=(${devices[*]})
                else
                    arrSelectedDevice=(${devices[$((choice-1))]})
                fi

                unset choice
                break
            else
                tips red "无效的输入, 请重新选择"
            fi
        done
    fi
}

function installApk()
{
    local ApkInfo=()

    cd $SCRIPT_HOME
    tips yellow "发现 $apkNum 个apk包, 请选择:"
    tips cyan "0: 跳过apk包安装，运行手机上已安装包"

    for index in ${!arrApkPath[@]}
    do
        apkPath=${arrApkPath[$index]}
        packageName=$(aapt d badging $apkPath | grep -Pos "(?<=package: name=').*?(?=')")
        appVersion=$(aapt d badging $apkPath | grep -Pos "(?<=versionName\=').*?(?=')")
        appLabel=$(aapt d badging $apkPath | grep -Pos "(?<=application-label:').*?(?=')")
        tips cyan "$((index+1)): $appLabel $appVersion ($packageName)"
        ApkInfo[$index]="$packageName,$appVersion,$apkPath,$appLabel"
    done

    until [ "$choice" -ge 0 -a "$choice" -le $apkNum ] 2>&-
    do
        tips -yellow "请选择待安装的apk包[q:退出]: "
        read choice

        if [ "$choice" == "q" ]; then
            exit 130
        fi

        if [ "$choice" -ge 0 -a "$choice" -le $apkNum ] 2>&-; then
            tips cyan "已选择: $choice"

            if [ "$choice" == "0" ]; then
                apkNum=0
            else
                local deviceId
                IFS=',' read packageName appVersion apkPath appLabel <<< "${ApkInfo[$((choice-1))]}"

                for deviceId in ${arrSelectedDevice[@]}
                do
                    adb -s $deviceId install -r $apkPath

                    if [ $? -eq 0 ]; then
                        arrRunDevice+=($deviceId)
                    else
                        arrSkipDevice+=($deviceId)
                        tips red "设备 ${dicDeviceBrand[$deviceId]} ${dicDeviceModel[$deviceId]} 上安装 ${appLabel} 失败, 设备号: $deviceId"
                    fi
                done
            fi

            unset choice
            break
        else
            tips red "无效的输入, 请重新选择"
        fi
    done
}

function findApp()
{
    tips cyan "\n正在检测应用(前缀: $packagePrefix)..."

    local deviceId=${arrSelectedDevice[0]}
    packages=($(timeout 60 adb -s $deviceId shell pm list packages -3 $packagePrefix 2>&- | grep -Pos '(?<=package:).*'))

    if [ ${#packages} -eq 0 ]; then
         tips red "首次运行,请在手机上开启文件传输模式"
         exit 126
    fi

    packageNum=${#packages[@]}

    if [ $packageNum -eq 0 ]; then
        tips red "未安装$packagePrefix前缀的应用"
        exit 127
    fi

    timeout 5 adb -s $deviceId push $MONKEY_HOME/push/sdcard/*.jar /sdcard &>/dev/null

    if [ $? -ne 0 ]; then
         tips red "向手机推送monkey运行包超时，可能手机安全软件占用adb端口，请重试"
         exit 126
    fi

    timeout 5 adb -s $deviceId push $MONKEY_HOME/push/data/local/tmp/* /data/local/tmp/ >&-

    if [ $? -ne 0 ]; then
         tips red "向手机推送monkey运行包超时，可能手机安全软件占用adb端口，请重试"
         exit 126
    fi

    # 向手机推送黑名单文件
    local strFile=($(ls $MONKEY_HOME/*.strings 2>&-))
    if [ ${#strFile[@]} -ne 0 ]; then
        tagFile=$(basename ${strFile[0]})
        if [ -s ${strFile[0]} -a $tagFile = "abl.strings" ] ; then
            abwlPara="--act-blacklist-file"
            abwlFile="/sdcard/$tagFile"
        elif [ -s ${strFile[0]} -a $tagFile = "awl.strings" ] ; then
            abwlPara="--act-whitelist-file"
            abwlFile="/sdcard/$tagFile"
        fi

        timeout 5 adb -s $deviceId push $MONKEY_HOME/$tagFile /sdcard >&-
        
        if [ $? -ne 0 ]; then
            tips red "向手机推送monkey黑名单文件超时，可能手机安全软件占用adb端口，请重试"
            exit 126
        fi
    fi

    arrRunDevice=($deviceId)

    if [ $packageNum -eq 1 ]; then
        packageName=${packages[0]}
        tips cyan "发现${packagePrefix}前缀的应用: $packageName"
        appPath=$(timeout 3 adb -s $deviceId shell pm path $packageName | grep -Pos '(?<=package:).*')
        appLabel=$(timeout 3 adb -s $deviceId shell /data/local/tmp/aapt d badging $appPath | grep -Pos "(?<=application-label:').*?(?=')")
        appVersion=$(timeout 3 adb -s $deviceId shell /data/local/tmp/aapt d badging $appPath | grep -Pos "(?<=versionName\=').*?(?=')")
        appVersion=${appVersion%??????????}
    else
        appPaths=()
        appLabels=()

        tips cyan "发现 $packageNum 个${packagePrefix}前缀的应用:"

        for index in ${!packages[@]}
        do
            appPath=$(timeout 3 adb -s $deviceId shell pm path ${packages[$index]} | grep -Pos '(?<=package:).*')
            appLabel=$(timeout 3 adb -s $deviceId shell /data/local/tmp/aapt d badging $appPath | grep -Pos "(?<=application-label:').*?(?=')")
            appPaths[$index]=$appPath
            appLabels[$index]=$appLabel

            if [ -z "$appLabel" ]; then
                tips cyan "$((index+1)): ${packages[$index]}"
            else
                tips cyan "$((index+1)): $appLabel (${packages[$index]})"
            fi
        done

        until [ "$choice" -ge 1 -a "$choice" -le $packageNum ] 2>&-
        do
            tips -yellow "请选择应用[q:退出]: "
            read choice

            if [ "$choice" == "q" ]; then
                exit
            fi

            if [ "$choice" -ge 1 -a "$choice" -le $packageNum ] 2>&-; then
                tips cyan "已选择: $choice"
                packageName=${packages[$((choice-1))]}
                appPath=${appPaths[$((choice-1))]}
                appLabel=${appLabels[$((choice-1))]}
                appVersion=$(timeout 3 adb -s $deviceId shell /data/local/tmp/aapt d badging $appPath | grep -Pos "(?<=versionName\=').*?(?=')")
                appVersion=${appVersion%??????????}
                unset choice
                break
            else
                tips red "无效的输入, 请重新选择"
            fi
        done
    fi
}

function findAppInMultiDevice()
{
    tips cyan "\n正在多台设备中检测应用(前缀: $packagePrefix)..."

    local deviceId package

    for deviceId in ${arrSelectedDevice[*]}
    do
        packages=($(timeout 3 adb -s $deviceId shell pm list packages -3 $packagePrefix 2>&- | grep -Pos '(?<=package:).*'))

        if [ ${#packages[*]} -ne 0 ]; then
            timeout 30 adb -s $deviceId push $MONKEY_HOME/push/sdcard/*.jar /sdcard &>/dev/null

            if [ $? -ne 0 ]; then
                tips red "首次运行,请在手机上开启文件传输模式, 如已开启，可能手机安全软件占用adb端口，请重试"
                continue
            fi

            timeout 5 adb -s $deviceId push $MONKEY_HOME/push/data/local/tmp/* /data/local/tmp/ >&-

            if [ $? -ne 0 ]; then
                tips red "向手机推送monkey运行包超时，可能手机安全软件占用adb端口，请重试"
                continue
            fi

            # 向手机推送黑名单文件
            local strFile=($(ls $MONKEY_HOME/*.strings 2>&-))
            if [ ${#strFile[@]} -ne 0 ]; then
                tagFile=$(basename ${strFile[0]})
                if [ -s ${strFile[0]} -a $tagFile = "abl.strings" ] ; then
                    abwlPara="--act-blacklist-file"
                    abwlFile="/sdcard/$tagFile"
                elif [ -s ${strFile[0]} -a $tagFile = "awl.strings" ] ; then
                    abwlPara="--act-whitelist-file"
                    abwlFile="/sdcard/$tagFile"
                fi

                timeout 5 adb -s $deviceId push $MONKEY_HOME/$tagFile /sdcard >&-

                if [ $? -ne 0 ]; then
                    tips red "向手机推送monkey黑名单文件超时，可能手机安全软件占用adb端口，请重试"
                    exit 126
                fi
            fi

            for package in ${packages[@]}
            do
                if [ -z "${dicDevices[$package]}" ]; then
                    dicDevices[$package]="$deviceId"
                else
                    dicDevices[$package]+=" $deviceId"
                fi
            done
        fi
    done

    packageNum=${#dicDevices[*]}

    if [ $packageNum -eq 0 ]; then
        tips red "所选设备上均未安装${packagePrefix}前缀的应用"
        exit 127
    fi

    if [ $packageNum -eq 1 ]; then
        packageName="${!dicDevices[*]}"
        tips cyan "发现1个 ${packagePrefix} 前缀的应用: $packageName"
    else
        tips cyan "发现 $packageNum 个 ${packagePrefix} 前缀的应用:"

        packageList=(${!dicDevices[*]})

        for index in ${!packageList[*]}
        do
            tips cyan "$((index+1)): ${packageList[$index]}"
        done

        until [ "$choice" -ge 1 -a "$choice" -le $packageNum ] 2>&-
        do
            tips -yellow "请选择应用[q:退出]: "
            read choice

            if [ "$choice" == "q" ]; then
                exit
            fi

            if [ "$choice" -ge 1 -a "$choice" -le $packageNum ] 2>&-; then
                tips cyan "已选择: $choice"
                packageName=${packageList[$((choice-1))]}
                arrRunDevice=(${dicDevices[$packageName]})
                selectedDeviceList=" ${arrSelectedDevice[*]}"

                for deviceId in ${arrRunDevice[*]}
                do
                    selectedDeviceList=${selectedDeviceList/ $deviceId}
                done

                arrSkipDevice=($selectedDeviceList)

                unset choice
                break
            else
                tips red "无效的输入, 请重新选择"
            fi
        done
    fi
}

function setRunMinutes()
{
    until [ "$runMinutes" -gt 0 ] 2>&-
    do
        tips -yellow "请输入运行时间,单位:分钟[q:退出]: "
        read runMinutes

        if [ "$runMinutes" == "q" ]; then
            exit
        elif [ "$runMinutes" -gt 0 ] 2>&-; then
            break
        else
            tips red "无效的输入, 请重新输入"
        fi
    done
}

function runMonkey()
{
    local deviceId=$1
    local packageName=$2
    local monkeyLog="monkey.log"
    # local index=$((deviceIndex+1))
    local flag=$(date +'%Y%m%d-%H%M%S')
    local deviceIndex=${dicDeviceIndex[$deviceId]}
    local deviceName="${dicDeviceBrand[$deviceId]} ${dicDeviceModel[$deviceId]}"

    tips yellow "在 $deviceName 上运行 ${appLabel} 健壮性测试..."
    
    timeout 3 adb -s $deviceId shell dumpsys batterystats --reset &>/dev/null

    timeout 3 adb -s $deviceId shell mv /sdcard/oom-traces.log /sdcard/oom-traces.log-$flag 2>&-
    timeout 3 adb -s $deviceId shell mv /sdcard/crash-dump.log /sdcard/crash-dump.log-$flag 2>&-

    if [ $runDeviceNum -eq 1 ]; then
        logPath="$RESULT_PATH"
    else
        logIndex="-$deviceIndex"
        logPath="$RESULT_PATH/device-$deviceIndex"
    fi

    mkdir -p $logPath
    cd $logPath

    collect $runMinutes &
    collectJob=$!

    beginTime=$(date +'%Y-%m-%d %H:%M:%S')

    if [ $runDeviceNum -eq 1 ]; then
        adb -s $deviceId shell \
            CLASSPATH=/sdcard/monkeyq.jar:/sdcard/framework.jar:/sdcard/fastbot-thirdpart.jar \
            exec app_process /system/bin com.android.commands.monkey.Monkey \
            -p $packageName --agent reuseq $abwlPara $abwlFile --running-minutes $runMinutes --throttle $throttle -v -v | tee -a $monkeyLog
    else
        adb -s $deviceId shell \
            CLASSPATH=/sdcard/monkeyq.jar:/sdcard/framework.jar:/sdcard/fastbot-thirdpart.jar \
            exec app_process /system/bin com.android.commands.monkey.Monkey \
            -p $packageName --agent reuseq $abwlPara $abwlFile --running-minutes $runMinutes --throttle $throttle -v -v > $monkeyLog
    fi

    endTime=$(date +'%Y-%m-%d %H:%M:%S')

    timeout 3 adb -s $deviceId pull /sdcard/fastbot-${packageName}--running-minutes-$runMinutes &>/dev/null
    timeout 3 adb -s $deviceId pull /sdcard/fastbot_${packageName}.fbm &>/dev/null
    timeout 3 adb -s $deviceId pull /sdcard/crash-dump.log &>/dev/null
    timeout 3 adb -s $deviceId pull /sdcard/oom-traces.log &>/dev/null

    monkeyResult=$(tail -4 $monkeyLog 2>&-)
    anrCount=$(grep -Pos '(?<= crash, )\d+(?= anr,)' <<< "$monkeyResult")
    crashCount=$(grep -Pos '(?<=App appears )\d+(?= crash,)' <<< "$monkeyResult")
    coverage=$(awk -F'[% ]' '/Activity of Coverage:/{printf("%.2f",$6)}' <<< "$monkeyResult")
    # 获取设备执行后的应用耗电
    deviceUID=$(timeout 3 adb -s $deviceId shell ps|grep $packageName|awk -F ' ' '{print $1}'|sed 's/_//g'|sed -n '1p')
    deviceBattery=$(timeout 3 adb -s $deviceId shell dumpsys batterystats "$packageName"|grep $deviceUID|grep Uid|awk -F ' ' '{print $3}')
    # 获取设备执行后的温度
    deviceTemp=$(timeout 3 adb -s $deviceId shell dumpsys battery|grep temperature|awk -F ' ' '{print $2}')
    deviceTemp=$(echo "scale=1;$deviceTemp/10"|bc)
    deviceTemperature="${dicDeviceTemp1[$deviceId]} ~ $deviceTemp"

    if [ -z "$anrCount" ]; then
        anrCount=$(grep -cs "// ANR: " crash-dump.log)
    fi

    if [ -z "$crashCount" ]; then
        crashCount=$(grep -cs "// CRASH: " crash-dump.log)
    fi

    anrCount=${anrCount:-0}
    crashCount=${crashCount:-0}
    failCount=$((anrCount+crashCount))

    if [ -z "${coverage}" ]; then
        coverage=0
        tips red "健壮性测试异常结束, 详情请查看以上信息"
        monkeyResult=$(grep -vE '[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.[0-9]{3}]' <<< "$monkeyResult")
        testInfo=${monkeyResult//\[Fastbot\]}
        testResult="异常"
        ret=2
    else
        testInfo="经过 $runMinutes 分钟测试, "
        if [ $failCount -eq 0 ]; then
            testInfo+="暂未发现程序崩溃与无响应现象。"
            tips green $testInfo
            testResult="通过"
            ret=0
        else
            testInfo+="共出现 $crashCount 次程序崩溃, $anrCount 次程序无响应。"
            mkdir -p "$ERROR_LOG_PATH"
            tips red $testInfo
            testResult="失败"
            ret=1
        fi
    fi

    wait $collectJob 2>&-
    genReport $deviceId $packageName
    return $ret
}

function genReport()
{
    local deviceId=$1
    local packageName=$2
    local deviceIndex=${dicDeviceIndex[$deviceId]}
    local deviceBrand=${dicDeviceBrand[$deviceId]}
    local deviceModel=${dicDeviceModel[$deviceId]}
    local androidVersion=${dicDeviceAndroid[$deviceId]}

    local exceptStyle="$passStyle"
    local deviceInfo="Device Model: $deviceModel, Android Version: $androidVersion, Device ID: $deviceId"

    if [ "$testResult" == "通过" ]; then
        local resultStyle="$passStyle"
    else
        local resultStyle="$highlightStyle"
    fi

    if [ -s "crash-dump.log" ]; then
        exceptStyle="$highlightStyle"
        sed -i "1i${deviceInfo}\n" crash-dump.log
        cp crash-dump.log $ERROR_LOG_PATH/crash-dump-$deviceIndex.log
    fi

    if [ $runDeviceNum -eq 1 ]; then
        local report="$RESULT_PATH/report.html"
    else
        local report="$RESULT_PATH/device-$deviceIndex/report.html"
    fi

    testInfo="${appLabel} 健壮性测试${testResult}, $testInfo"

    # 生成报告时转换图片base64
    imgFile=$(ls report.png 2>&-)
    if [ -n "$imgFile" ]; then
        imgFile=$(base64 $imgFile 2>&-)
        img="<img src='data:image/jpeg;base64,$imgFile' alt='统计图'>"
    fi

    echo "
    <!DOCTYPE html PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN'>
    <html>
    <head>
    <meta http-equiv='Content-Type' content='text/html; charset=UTF-8'>
    <title>健壮性测试报告</title>
    </head>
    <body>
    <h1>${appLabel}健壮性测试报告</h1>
    <hr align='center' width=0 size=1>
    <h3>应用名称: ${appLabel}</h3>
    ${appVersionInfo}
    <h3>应用包名: ${packageName}</h3>
    <h3>测试时长: ${runMinutes} 分钟</h3>
    <h3>Crash次数: ${crashCount}</h3>
    <h3>ANR次数: ${anrCount}</h3>
    <h3>测试覆盖率: ${coverage}%</h3>
    <h3>手机型号: ${deviceBrand} ${deviceModel}</h3>
    <h3>安卓版本: ${androidVersion}</h3>
    <h3>应用耗电: ${deviceBattery} mAh</h3>
    <h3>设备温度: ${deviceTemperature} ℃</h3>
    <h3>开始时间: ${beginTime}</h3>
    <h3>结束时间: ${endTime}</h3>
    <hr size=1>
    <h2>测试结论</h2>
    <h3 style='${resultStyle}'>${testInfo}</h3>
    ${img}
    <hr size=1>
    <h2>异常日志:</h2>
    <pre id='exception' style='$exceptStyle'>
    </pre>
    </body>
    </html>" > $report

    sed -i "s/^\s*//g" $report

    if [ -s "crash-dump.log" ]; then
        sed -i "/<pre id='exception'/r crash-dump.log" $report
    else
        sed -i "/<pre id='exception'/a\健壮性测试期间未发现Crash与ANR" $report
    fi
}

function genMergeReport()
{
    local testResult resultTable anrResult crashResult description resultStyle anrStyle crashStyle mergeReport

    mergeReport="$RESULT_PATH/report.html"
    description="健壮性测试运行 ${runMinutes} 分钟, 共测试 ${runDeviceNum} 台手机, ${passDeviceNum} 台手机测试通过"

    if [ $failDeviceNum -eq 0 ]; then
        testResult="通过"
        resultStyle="$passStyle"
    else
        testResult="不通过"
        resultStyle="$highlightStyle"
        description+=", $failDeviceNum 台手机测试失败"
    fi

    if [ $abnormalDeviceNum -ne 0 ]; then
        description+=", $abnormalDeviceNum 台手机异常退出"
    fi

    for index in ${!arrResult[@]}
    do
        resultTable+="<tr><td>$((index))</td><td>${arrResult[$index]//,/</td><td>}</td></tr>\n"
        # 获取每台设备的report.png
        png=$(ls $RESULT_PATH/device-$index/report.png 2>&-)
        if [ -n "$png" ]; then
            png=$(base64 $png 2>&-)
            mergeReportImg+="<div><img src='data:image/jpeg;base64,$png' alt='统计图'></div>\n"
        fi
    done

    if [ $crashTotal -eq 0 ]; then
        crashStyle="$passStyle"
        crashResult="暂未出现程序崩溃现象。如有必要, 请增加测试时长。"
    else
        crashStyle="$failStyle"
        crashResult="共出现过 ${crashTotal} 次程序崩溃现象"

        if [ -d "$ERROR_LOG_PATH" ]; then
            cd "$ERROR_LOG_PATH"
            arrCrashDevice=($(grep -ls -m 1 '// CRASH: ' crash-dump-*.log | grep -oE '[0-9]+'))
            crashDeviceNum=${#arrCrashDevice[*]}
            eval $(awk '/^\/\/ Long Msg: / {sub("// Long Msg: ","");print "arrAnrReason+=(\""$0"\")"}' crash-dump-*.log 2>&-)

            arrCrashType=()
            arrCrashCount=()
            crashStat=$(grep -Posh '(?<=// Long Msg: ).*' crash-dump-* | sort | uniq -c | sort -r)
            eval $(awk '{count=$1;$1="";sub("^ ","",$0);print "arrCrashType+=(\""$0"\");arrCrashCount+=("count")"}' <<< "$crashStat")

            crashTypeNum=${#arrCrashType[*]}

            if [ $crashTypeNum -eq 1 ]; then
                crashResult+=", Crash原因: <br>\n"
                crashResult+="${arrCrashType[0]}<br>\n"
            else
                for index in ${!arrCrashType[*]}
                do
                    crashTable+="<tr><td>$((index+1))</td><td>${arrCrashType[$index]}</td><td>${arrCrashCount[$index]}</td></tr>\n"
                done

                crashResult+=", Crash类型共有 ${crashTypeNum} 种:<br>
                <table border=1 style='color:red'>
                <tr align='center'><td>序号</td><td>Crash类型</td><td>Crash数量</td></tr>
                $crashTable
                </table>
                "
            fi

            if [ $crashDeviceNum -eq 1 ]; then
                deviceIndex=${arrCrashDevice[0]}
                deviceId=${arrRunDevice[$((deviceIndex-1))]}
                deviceBrand=${dicDeviceBrand[$deviceId]}
                deviceModel=${dicDeviceModel[$deviceId]}
                androidVersion=${dicDeviceAndroid[$deviceId]}
                crashResult+="<p>出现Crash的设备是 ${deviceBrand} ${deviceModel}, android版本: ${androidVersion}\n"
            else
                crashResult+="<p>出现Crash的设备共有 ${crashDeviceNum} 台:<br>\n"

                for index in ${!arrCrashDevice[*]}
                do
                    deviceIndex=${arrCrashDevice[$index]}
                    deviceId=${arrRunDevice[$((deviceIndex-1))]}
                    deviceBrand=${dicDeviceBrand[$deviceId]}
                    deviceModel=${dicDeviceModel[$deviceId]}
                    androidVersion=${dicDeviceAndroid[$deviceId]}
                    crashResult+="$((index+1)). ${deviceBrand} ${deviceModel} (android ${androidVersion})<br>\n"
                done
            fi

            crashResult+="<p>Crash详情，请查看附件中crash-dump日志\n"
        fi
    fi

    if [ $anrTotal -eq 0 ]; then
        anrStyle="$passStyle"
        anrResult="暂未出现程序无响应现象。如有必要, 请增加测试时长。"
    else
        anrStyle="$failStyle"
        anrResult="共出现 ${anrTotal} 次程序无响应现象, "

        if [ -d "$ERROR_LOG_PATH" ]; then
            cd "$ERROR_LOG_PATH"

            arrAnrDevice=($(grep -ls -m 1 '// ANR: ' crash-dump-*.log | grep -oE '[0-9]+'))
            anrDeviceNum=${#arrAnrDevice[*]}

            arrAnrReason=()
            arrAnrActivity=()
            eval $(awk '/^Reason: / {sub("Reason: ","");print "arrAnrReason+=(\""$0"\")"}' crash-dump-*.log 2>&-)
            eval $(awk '/^\/\/ NOT RESPONDING: / {gsub(/(\/\/.*\/|\))/,"");print "arrAnrActivity+=("$0")"}' crash-dump-*.log 2>&-)
            arrAnrActivitys=($(xargs -n 1  <<< "${arrAnrActivity[*]}" | sort -u))
            anrActivityNum=${#arrAnrActivitys[*]}

            if [ $anrActivityNum -eq 1 ]; then
                anrReasonNum=${#arrAnrReason[*]}
                if [ $anrReasonNum -gt 0 ]; then
                    anrReasons="<br>导致ANR的原因:<br>\n"

                    if [ $anrReasonNum -eq 1 ]; then
                        anrReasons+=${arrAnrReason[0]}
                    else
                        for index in ${arrAnrReason[*]}
                        do
                            anrReasons+="$((index+1)). ${arrAnrReason[$index]}\n"
                        done
                    fi
                fi
                anrResult+="出现ANR的Activity是 ${arrAnrActivitys[0]}<br>\n${anrReasons}"
            else
                for index in ${!arrAnrActivitys[*]}
                do
                    anrActivitys+="$((index+1)). ${arrAnrActivitys[$index]}<br>\n"
                done

                for index in ${!arrAnrActivity[*]}
                do
                    anrReasons+="<tr><td>$((index+1))</td><td>${arrAnrActivity[$index]}</td><td>${arrAnrReason[$index]}</td></tr>\n"
                done

                anrResult+="
                出现ANR的Activity共有 ${anrActivityNum} 个:<br>
                ${anrActivitys}
                <br>导致ANR的原因:<br>
                <table border=1 style='color:red'>
                <tr align='center'><td>序号</td><td>activity名称</td><td>ANR原因</td>
                ${anrReasons}
                </table>
                "
            fi

            if [ $anrDeviceNum -eq 1 ]; then
                deviceIndex=${arrAnrDevice[0]}
                deviceId=${arrRunDevice[$((deviceIndex-1))]}
                deviceBrand=${dicDeviceBrand[$deviceId]}
                deviceModel=${dicDeviceModel[$deviceId]}
                androidVersion=${dicDeviceAndroid[$deviceId]}
                anrResult+="<p>出现ANR的设备是 ${deviceBrand} ${deviceModel}, android版本: ${androidVersion}\n"
            else
                anrResult+="<p>出现ANR的设备共有 ${anrDeviceNum} 台:<br>\n"

                for index in ${!arrAnrDevice[*]}
                do
                    deviceIndex=${arrAnrDevice[$index]}
                    deviceId=${arrRunDevice[$((deviceIndex-1))]}
                    deviceBrand=${dicDeviceBrand[$deviceId]}
                    deviceModel=${dicDeviceModel[$deviceId]}
                    androidVersion=${dicDeviceAndroid[$deviceId]}
                    anrResult+="$((index+1)). ${deviceBrand} ${deviceModel} (android ${androidVersion})<br>\n"
                done
            fi

            anrResult+="<p>ANR详情, 请查看附件中crash-dump日志\n"
        fi
    fi

    echo -e "
    <!DOCTYPE html PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN'>
    <html>
    <head>
    <meta http-equiv='Content-Type' content='text/html; charset=UTF-8'>
    <title>健壮性测试报告</title>
    </head>
    <body>
    <h1>${appLabel}健壮性测试报告</h1>
    <hr align='center' width=0 size=1>
    <h3>应用名称: ${appLabel}</h3>
    ${appVersionInfo}
    <h3>应用包名: ${packageName}</h3>
    <h3>测试时长: ${runMinutes} 分钟</h3>
    <h3>Crash总数: ${crashTotal}</h3>
    <h3>ANR总数: ${anrTotal}</h3>
    <h3>测试手机: ${runDeviceNum}台</h3>
    <h3>开始时间: ${begin}</h3>
    <h3>结束时间: ${end}</h3>
    <hr size=1>
    <h2>测试结论</h2>
    <h3 style='${resultStyle}'>${appLabel}健壮性测试${testResult}</h3>
    <p>${description}</p>
    <p>所有手机运行结果:</p>
    <table border=1 style='text-align: center'>
    <tr><td>序号</td><td>手机品牌</td><td>手机型号</td><td>安卓版本</td><td>应用版本</td><td>Crash次数</td><td>ANR次数</td><td>Activity覆盖率</td><td>应用耗电mAh</td><td>设备温度℃</td><td>测试结果</td></tr>
    ${resultTable}
    </table>
    ${mergeReportImg}
    <p>
    <hr size=1>
    <h2>Crash检查结果:</h2>
    <div id='crash' style='${crashStyle}'>
    ${crashResult}
    </div>

    <p>
    <hr size=1>
    <h2>ANR检查结果:</h2>
    <div id='anr' style='${anrStyle}'>
    ${anrResult}
    </div>

    </body>
    </html>
    " > $mergeReport

    sed -i "s/^\s*//g" $mergeReport
}

function sendReport()
{
    if [ "$isSendReport" != "true" ]; then
        return 1
    fi

    local attachment
    local report="$RESULT_PATH/report.html"
    mailSubject="${appLabel}${mailSubject}"

    rmdir "$ERROR_LOG_PATH" 2>&-

    if [ -d "$ERROR_LOG_PATH" ]; then
        cd "$ERROR_LOG_PATH"
        attachment="errorlog.zip"
        zip -rq "$attachment" *

        if [ $? -ne 0 ]; then
            unset attachment
        fi
    fi

    sendEmail -t $mailTo -u "$mailSubject" -o message-file="$report" ${mailCc:+-cc $mailCc} ${mailBcc:+-bcc $mailBcc} ${attachment:+-a "$attachment"}

    if [ $? -eq 0 ]; then
        tips green "Test report sent successfully."

        if [ -n "$attachment" ]; then
            rm -f $attachment
        fi
    else
        tips red "Failed to send test report."
        return 1
    fi
}

function tips()
{
    local para message colors nowrap

    para=$1
    shift
    message="$*"

    if [ ${#para} -eq 0 ]; then
        return 128
    fi

    if [ "${para:0:1}" == "-" ]; then
        nowrap="\c"
        para=${para:1}
    fi

    case "$para" in
        red)
            color=31;;
        green)
            color=32;;
        yellow)
            color=33;;
        cyan)
            color=36;;
        *)
            echo -e "${para:+$para }$message$nowrap"
            return 0
            ;;
    esac

    if [ ${#message} -eq 0 ]; then
        return 128
    else
        echo -e "\033[${color}m$message\033[0m$nowrap"
    fi
}

function getDevicesName()
{
    local para brand
    brand=$1
    case "$brand" in
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

function collectData()
{
    local deviceId=$1
    local packageName=$2
    local counter=$3

    deviceUID=$(timeout 3 adb -s $deviceId shell ps|grep $packageName|awk -F ' ' '{print $1}'|sed 's/_//g'|sed -n '1p')
    deviceBattery=$(timeout 3 adb -s $deviceId shell dumpsys batterystats "$packageName"|grep $deviceUID|grep Uid|awk -F ' ' '{print $3}')
    if [ ! -n "$deviceBattery" ]; then
        deviceBattery=0
    fi

    if [ ! -s Battery.info ]; then
        echo "date time deviceBattery" > Battery.info
    fi

    date +"$counter %Y-%m-%d %H:%M:%S $deviceBattery" >> Battery.info

    deviceTemp=$(timeout 3 adb -s $deviceId shell dumpsys battery|grep temperature|awk -F ' ' '{print $2}')
    deviceTemp=$(echo "scale=1;$deviceTemp/10"|bc)

    if [ ! -s Temperature.info ]; then
        echo "date time temperature" > Temperature.info
    fi

    date +"$counter %Y-%m-%d %H:%M:%S $deviceTemp" >> Temperature.info

    # 三、获取当前页面帧率（应根据每个activity获取）
    # currentActivity=$(timeout 3 adb -s $deviceId shell CLASSPATH=/sdcard/monkey.jar:/sdcard/framework.jar \
    #  exec app_process /system/bin tv.panda.test.monkey.api.CurrentActivity|grep //|awk -F ' ' '{print $3}')                 # 获取当前activity
    # activityFps=$(timeout 3 adb -s $deviceId shell dumpsys gfxinfo $packagename|grep Jankey|awk -F '[(|)]' '{print $2}')    # 丢包率
    # date +"$counter %Y-%m-%d %H:%M:%S $currentActivity $activityFps" >> fps.info
    
    if [ -n "$packageName" ]; then
        echo "collect info for package"
    fi 
}

function collect()
{
    local duration interval count counter
    duration=$1

    if [ "$duration" -ge 600 ] 2>&-; then
        interval=300
    elif [ "$duration" -ge 60 -a "$duration" -lt 600 ] 2>&-; then
        interval=60
    elif [ "$duration" -ge 5 -a "$duration" -lt 60 ] 2>&-; then
        interval=15
    else
        # return 128
        interval=5
    fi

    counter=0
    count=$((duration*60/interval))

    while [ $counter -lt $count ]
    do
        counter=$((counter+1))
        collectData $deviceId $packageName $counter
        sleep $interval
    done

    arrInfo=($(ls *.info 2>&-))
    genChart ${arrInfo[@]}
}

function genChart()
 {
    function gen_gnuplot
    {
        arrFile=$@

        echo -n "
        set terminal pngcairo size 2000,250;
        set output 'report.png';
        set xrange [0.5:];
        unset key;
        set multiplot;"

        i=0
        for file in $arrFile
        do
            local filename=$(basename $file .info)
            echo -n "
            set title '$filename';
            set origin 0.25*$i,0.0;
            set size 0.25,1.0;
            plot '<sed 1d $file' u 1:4 w lp pt 7 ps 0.3"
            i=$((i+1))
        done
    }

    gen_gnuplot "$@"|gnuplot 2>/dev/null
}

main "$@"

exit 0
