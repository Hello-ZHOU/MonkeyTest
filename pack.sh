#!/bin/bash

sourceFile="monkey.sh"
targetBin="monkey"

curPath=$PWD
SCRIPT_HOME=$(cd $(dirname ${BASH_SOURCE[0]});pwd)

cd $SCRIPT_HOME/utils
MD5=$(find -type f -exec md5sum {} \; | sort -k2 | md5sum | awk '{print $1}')

if grep -Eoq '^MD5=".*"\s*$' $SCRIPT_HOME/$sourceFile; then
    sed -i "/^MD5=\".*\"\s*$/s/.*/MD5=\"$MD5\"/" $SCRIPT_HOME/$sourceFile
else
    sed -i "/^MONKEY_HOME=/a\MD5=\"$MD5\"" $SCRIPT_HOME/$sourceFile
fi

tar zcf depends.tar.gz *

cat $SCRIPT_HOME/$sourceFile depends.tar.gz > $SCRIPT_HOME/$targetBin
chmod +x $SCRIPT_HOME/$targetBin

rm -f depends.tar.gz &

cd $curPath

