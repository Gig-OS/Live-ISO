#!/bin/bash

# 给社区 binhost 的签名公钥建立 portage 的信任。
#
# binrepos.conf 里写了 verify-signature = true，portage 会用 /etc/portage/gnupg 这个独立钥匙环
# 验签，而不是用户的个人钥匙环。该钥匙环由 getuto 初始化，公钥来自 sec-keys/openpgp-keys-gentoozh，
# 导入后还要 lsign 一次，否则密钥虽在但不被信任，验签仍然不过。
#
# 在构建期做完，用户开箱即可用二进制包。任一步失败只警告不中止：验签配不上时 portage 会拒绝
# 该源的包并改为编译源码，属可用的退化，不该让整锅构建失败。

GIGOS_BINHOST_KEY=6A0726AF1476A2F382C6AC6638A0234EC16AD42E
GIGOS_KEY_ASC=/usr/share/openpgp-keys/gentoozh.asc

if ! [ -f "${WORKDIR}/squashfs${GIGOS_KEY_ASC}" ]; then
    echo "[06-binhost] 警告：${GIGOS_KEY_ASC} 不在(sec-keys/openpgp-keys-gentoozh 漏装?)，跳过验签配置"
elif ! crun 'command -v getuto >/dev/null 2>&1'; then
    echo "[06-binhost] 警告：chroot 内没有 getuto，跳过验签配置"
else
    # getuto 幂等，已初始化时不会重建钥匙环
    crun getuto || echo "[06-binhost] 警告:getuto 返回非零，继续尝试导入"
    if crun "gpg --homedir /etc/portage/gnupg --import ${GIGOS_KEY_ASC}"; then
        # lsign 需要 getuto 存下的口令，它在 /etc/portage/gnupg/pass
        crun "gpg --homedir /etc/portage/gnupg --batch --yes --pinentry-mode loopback \
              --passphrase-file /etc/portage/gnupg/pass --lsign-key ${GIGOS_BINHOST_KEY}" \
            && crun 'gpg --homedir /etc/portage/gnupg --check-trustdb' \
            && echo "[06-binhost] 社区 binhost 公钥已导入并本地签名" \
            || echo "[06-binhost] 警告：本地签名或 trustdb 更新失败，该源的包将改为编译源码"
    else
        echo "[06-binhost] 警告：公钥导入失败，该源的包将改为编译源码"
    fi
fi

unset GIGOS_BINHOST_KEY GIGOS_KEY_ASC
