#!/bin/sh
# 把内置服务的二进制拷进 .app 并逐个签名。源目录是 macos/server/。
#
# 这两个可执行文件不走 Flutter assets：从 assets 释放出来的文件没有签名，硬化
# 运行时下 exec 会被系统拦下；而且「释放」意味着 bundle 内和应用支持目录各存
# 一份，白白多占一倍磁盘。放进 Contents/Resources/server/ 由 Xcode 连同 App
# 一起签名，运行时直接 exec。
set -e

SRC="${SRCROOT}/server"
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/server"

for exe in retainpdf-rs typst; do
  if [ ! -f "${SRC}/${exe}" ]; then
    echo "error: 缺少内置服务二进制 macos/server/${exe}" >&2
    echo "note: 这些产物体积大不入库，需要先从后端仓库构建后拷进 macos/server/" >&2
    exit 1
  fi
  # 架构对不上就在构建期喊停，否则要等到运行时 exec 失败才发现，那时只能看到
  # 一个没头没脑的 ProcessException。要同时支持 Intel 的话，用
  # `lipo -create arm64版 x64版 -output <exe>` 合成 universal binary 放这里。
  HAVE="$(lipo -archs "${SRC}/${exe}")"
  for arch in ${ARCHS}; do
    if ! echo "${HAVE}" | tr ' ' '\n' | grep -qx "${arch}"; then
      echo "error: ${exe} 不含 ${arch} 架构（实际为：${HAVE}）" >&2
      exit 1
    fi
  done
done

rm -rf "${DEST}"
mkdir -p "${DEST}"
rsync -a --exclude='.gitkeep' --exclude='.DS_Store' "${SRC}/" "${DEST}/"
# 源文件可能是只读的（typst 就是 r-xr-xr-x），后续 codesign 要写回签名段。
chmod -R u+w "${DEST}"

# Xcode 收尾只签 .app 本身，嵌在里面的可执行文件必须在这里签好。
#
# 注意这里没有「不签名」这个分支：Apple Silicon 上 arm64 可执行文件必须带签名
# 才能运行，没有的话内核在 exec 时直接 SIGKILL，连错误信息都拿不到。所以有
# Developer ID 就用它（可公证），没有就退回 ad-hoc（能跑，但用户首次打开要在
# 系统设置里手动放行）。
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
if [ -z "${IDENTITY}" ]; then
  IDENTITY="-"
fi

if [ "${IDENTITY}" = "-" ]; then
  # ad-hoc 不支持安全时间戳，硬化运行时对未公证的分发也没有意义。
  SIGN_FLAGS=""
else
  SIGN_FLAGS="--options runtime"
  # 公证要求安全时间戳，但它要联网，Debug 下没必要每次都等。
  if [ "${CONFIGURATION}" = "Release" ]; then
    SIGN_FLAGS="${SIGN_FLAGS} --timestamp"
  fi
fi

find "${DEST}" -type f -perm -u+x -exec \
  codesign --force ${SIGN_FLAGS} --sign "${IDENTITY}" {} \;
