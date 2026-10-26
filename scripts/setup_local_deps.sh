#!/usr/bin/env bash
# 在无 sudo 的 Ubuntu 22.04 上为 ninfer-2080ti-22g 准备依赖 + 配置构建。
#
# 这台机没有免密 sudo，所以走"下载 deb → dpkg-deb -x 提取 → 装进本地前缀"的路子，
# 全部落在 .local-deps/ 下，不动系统目录。
#
# 已解决的坑（每一行都是实际卡过的地方）：
#   1. cmake 需 ≥3.28（系统 3.22）→ 用 pip 装 cmake 3.31.6（**不要 4.x**：4.x 的 CUDA
#      编译器探测与本项目不兼容）
#   2. 七个依赖库全缺 → apt-get download + dpkg-deb -x 提进 .local-deps
#   3. liburing 需 ≥2.5（jammy 只有 2.0）→ 从 noble 提 liburing 2.5
#   4. libcurl 需 ≥7.85（jammy 只有 7.81）→ **从源码编 curl 8.5 并关掉 LDAP**
#      （noble 的 libcurl 8.5 依赖 OpenLDAP 2.6 → 要 glibc 2.38，本机只有 2.35）
#   5. liburing 2.5 的头要用 linux/io_uring.h 里的 io_uring_buf_ring（内核 5.19+）
#      → 从 noble 的 linux-libc-dev 提 **6.8** 那份放进本地前缀
#   6. hwloc 的 autogen/config.h 在 deb 的 **x86_64-linux-gnu/** 多架构子目录下
#      → 提取后要把两个 include 树合并，否则报 "hwloc/autogen/config.h: 没有那个文件"
#   7. CMake 认到了系统的 /usr/bin/nvcc（CUDA 11.5，不支持 C++20）→
#      必须显式 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.4/bin/nvcc
#   8. CUDA 13 不再支持 sm_52，编译器自检会失败 → -DCMAKE_CUDA_ARCHITECTURES=75
#   9. **整套内核 UAPI 头太旧**：jammy 是 5.15 → 缺 STATX_DIOALIGN（要 6.1）、
#      缺 io_uring_sqe.addr3（要 6.10）、缺 IORING_OP_SEND_ZC（要 6.10）→
#      从 **Debian trixie 的 linux-libc-dev 6.12** 提整个 linux/ 头树（纯 UAPI 头，与 glibc 无关）
#  10. Ubuntu 的 liburing-dev "2.5" 实际配了**新内核头**（它的 liburing.h 引用
#      IORING_OP_SEND_ZC / addr_len）→ 所以内核头必须 ≥6.10，6.8 那份不够。
#      反过来：上游 GitHub 的 liburing-2.5 tag 反而缺 compat.h，别用。
#  11. ffmpeg 的 .pc 里 includedir **自带 /x86_64-linux-gnu 后缀**（头装在多架构子目录）。
#      统一 sed 成 ${prefix}/include 会把后缀弄丢 → "libavcodec/avcodec.h: 没有那个文件"。
#      修法要分类：ffmpeg 那几个指回 include/x86_64-linux-gnu，hwloc/liburing/curl 留在 include/ 根下。
#  12. **pkg_check_modules 会缓存**：改了 .pc 也不重查（FFMPEG_INCLUDE_DIRS 是 cache 变量，
#      -U 清了也会被内部 guard 挡住）→ 正确做法是 rm -rf build/turing-release 重配。
#  13. **ffmpeg 版本要 ≥7.0**：项目用到 av_packet_side_data_get（FFmpeg 7.0 引入）与
#      AVCodecParameters.coded_side_data。jammy 是 4.4（libavcodec 58）→ 编译不过。
#      Debian trixie 的 ffmpeg 7.1 版本对，但它的编解码器依赖（libx264/libx265/libjxl/libvpl…）
#      要 GLIBC_2.38，本机只有 2.35 → **只能从源码编一个最小 FFmpeg 7.1**
#      （--disable-x86asm --disable-everything，只留项目用到的解码器/解复用器）。
#      → 提取后要把两个 include 树合并，否则报 "hwloc/autogen/config.h: 没有那个文件"
#   7. CMake 认到了系统的 /usr/bin/nvcc（CUDA 11.5，不支持 C++20）→
#      必须显式 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.4/bin/nvcc
#   8. CUDA 13 不再支持 sm_52，编译器自检会失败 → -DCMAKE_CUDA_ARCHITECTURES=75
#
#  14. **解包目录与 cmake venv 都不能放 /tmp**：脚本原来把 deb 解到 /tmp 再软链进前缀、
#      cmake venv 也在 /tmp —— /tmp 一被清，前缀里 22 个软链集体断掉，服务启动报
#      "error while loading shared libraries: liburing.so.2"。现在解包目录是
#      .local-deps/work、venv 是 .local-deps/cmake，都随仓库持久化。
#  15. **sed 不能读同一个文件又写回它**：`> file` 会先截断，sed 于是读到空 → 产出 0 字节的
#      libcurl.pc，后面 pkg-config 报 "appears to be empty"。要改写就写 .tmp 再 mv。
#
# 用法：
#   bash scripts/setup_local_deps.sh              # 装依赖 + 配置（会重配 build 目录）
#   SKIP_CONFIGURE=1 bash scripts/setup_local_deps.sh   # 只修依赖，保住已编译的二进制
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$REPO/.local-deps"
WORK="${WORK:-$PREFIX/work}"   # 必须持久：/tmp 会被清，
                                          # 软链指向 /tmp 会在几天后集体断掉
CMAKE_BIN="${CMAKE_BIN:-$PREFIX/cmake/bin}"   # 同理：/tmp 里的 venv 会被清
CUDA_ROOT="${CUDA_ROOT:-/usr/local/cuda-13.4}"
JOBS="${JOBS:-4}"

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/lib/x86_64-linux-gnu" "$PREFIX/include" "$WORK"
cd "$WORK"

step() { echo; echo "=== $* ==="; }

# ---- 1. cmake 3.31（系统 3.22 太旧；4.x 与本项目的 CUDA 探测不兼容）----
step "cmake 3.31.6"
if [ ! -x "$CMAKE_BIN/cmake" ] || ! "$CMAKE_BIN/cmake" --version | grep -q "3\.31"; then
  python3 -m venv "$PREFIX/cmake"
  "$CMAKE_BIN/pip" install -q -U pip
  "$CMAKE_BIN/pip" install -q -i https://mirrors.aliyun.com/pypi/simple/ "cmake==3.31.6"
fi
"$CMAKE_BIN/cmake" --version | head -1

# ---- 2. jammy 的库（ffmpeg / curl / hwloc / liburing 运行时）----
step "下载并提取 jammy deb"
PKGS="libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libavfilter-dev \
libswresample-dev libavformat58 libavcodec58 libavutil56 libswscale5 libswresample3 \
libavfilter7 libavdevice58 libpostproc55 libcurl4-openssl-dev libcurl4 \
libhwloc-dev libhwloc15 liburing-dev liburing2 libgomp1"
rm -rf jammy && mkdir jammy && cd jammy
apt-get download $PKGS 2>&1 | tail -2 || true
cd "$WORK"
rm -rf extract && mkdir extract
for d in jammy/*.deb; do dpkg-deb -x "$d" extract/ 2>/dev/null; done

# ---- 3. noble 的 liburing 2.5（jammy 只有 2.0，cmake 要 ≥2.5）----
step "noble liburing 2.5"
cd "$WORK"
# URL 直接写死：依赖包索引会让脚本在索引缺失时（而且 set -e 会让它静默中止）
mkdir -p noble
for F in "liburing-dev_2.5-1build1_amd64.deb" "liburing2_2.5-1build1_amd64.deb"; do
  [ -s "noble/$F" ] || curl -sSfL -o "noble/$F" "http://archive.ubuntu.com/ubuntu/pool/main/libu/liburing/$F" || true
done
rm -rf u25 && mkdir u25
for d in noble/liburing*.deb; do dpkg-deb -x "$d" u25/ 2>/dev/null || true; done

# ---- 4. noble 的 linux-libc-dev（liburing 2.5 要 io_uring_buf_ring，内核 5.19+）----
step "noble linux-libc-dev（io_uring.h）"
curl -sL -o noble/lcd.deb "http://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux-libc-dev_6.8.0-31.31_amd64.deb" || true
rm -rf lcd && mkdir lcd
dpkg-deb -x noble/lcd.deb lcd/ 2>/dev/null || true
# ---- 4. Debian trixie 的 linux-libc-dev 6.12（整套内核 UAPI 头，glibc 无关）----
step "Debian trixie linux-libc-dev 6.12（io_uring.h / stat.h 等）"
curl -sL -o noble/lcd612.deb "http://deb.debian.org/debian/pool/main/l/linux/linux-libc-dev_6.12.94-1_all.deb" || true
rm -rf lcd612 && mkdir lcd612
dpkg-deb -x noble/lcd612.deb lcd612/ 2>/dev/null || true
# ---- 5. 全部落到本地前缀 ----
step "安装到 $PREFIX"
for f in extract/usr/lib/x86_64-linux-gnu/*.so* extract/usr/lib/x86_64-linux-gnu/*.a; do
  [ -e "$f" ] && ln -sf "$PREFIX/work/extract/usr/lib/x86_64-linux-gnu/$(basename "$f")" "$PREFIX/lib/x86_64-linux-gnu/" || true
done
for f in u25/usr/lib/x86_64-linux-gnu/liburing.so*; do
  [ -e "$f" ] && ln -sf "$PREFIX/work/u25/usr/lib/x86_64-linux-gnu/$(basename "$f")" "$PREFIX/lib/x86_64-linux-gnu/"
done
cp -rf u25/usr/include/. "$PREFIX/include/" 2>/dev/null || true
# 内核 UAPI 头整树覆盖（6.12）：STATX_DIOALIGN / io_uring addr3 / IORING_OP_SEND_ZC
rm -rf "$PREFIX/include/linux" && mkdir -p "$PREFIX/include/linux"
cp -rf lcd612/usr/include/linux/. "$PREFIX/include/linux/" 2>/dev/null || true
# Ubuntu 的 liburing.h（要 6.10+ 内核头），含 compat.h / io_uring_version.h
rm -rf "$PREFIX/include/liburing" && mkdir -p "$PREFIX/include/liburing"
cp -f u25/usr/include/liburing.h "$PREFIX/include/liburing.h" 2>/dev/null || true
cp -f u25/usr/include/liburing/*.h "$PREFIX/include/liburing/" 2>/dev/null || true
cp -rf extract/usr/include/. "$PREFIX/include/" 2>/dev/null || true
cp -rf extract/usr/include/x86_64-linux-gnu/. "$PREFIX/include/" 2>/dev/null || true
cp -rf u25/usr/include/. "$PREFIX/include/" 2>/dev/null || true
mkdir -p "$PREFIX/include/linux"
cp -f lcd/usr/include/linux/io_uring.h "$PREFIX/include/linux/" 2>/dev/null || true
# pkg-config：把 prefix 改成本地前缀
for pc in extract/usr/lib/x86_64-linux-gnu/pkgconfig/*.pc u25/usr/lib/x86_64-linux-gnu/pkgconfig/*.pc; do
  [ -f "$pc" ] || continue
  n=$(basename "$pc")
  # ⚠️ ffmpeg 那几个的 includedir 原本就带 /x86_64-linux-gnu 后缀（头装在多架构子目录），
  #    统一改成 ${prefix}/include 会把后缀弄丢 → 报 "libavcodec/avcodec.h: 没有那个文件"。
  #    其它库（hwloc/liburing/curl）的头在 include/ 根下，**不能**加后缀。
  # libcurl.pc 属于**源码编译**的 curl 8.5，deb 里那份是 7.81 —— 不能覆盖它
  [ "$n" = "libcurl.pc" ] && continue
  case "$n" in
    libav*.pc|libsw*.pc) inc='${prefix}/include/x86_64-linux-gnu' ;;
    *)                    inc='${prefix}/include' ;;
  esac
  sed -e "s|^prefix=.*|prefix=$PREFIX|" \
      -e "s|^libdir=.*|libdir=\${prefix}/lib/x86_64-linux-gnu|" \
      -e "s|^includedir=.*|includedir=$inc|" "$pc" > "$PREFIX/lib/pkgconfig/$n"
done

# ---- 6. curl 8.5（无 LDAP）：noble 的 libcurl 依赖 OpenLDAP 2.6 → glibc 2.38，本机 2.35 ----
step "检查已装的 curl / ffmpeg"
[ -e "$PREFIX/lib/libcurl.so.4" ] && echo "  curl 8.5 已装，跳过编译"
[ -e "$PREFIX/lib/libavcodec.so.61" ] && echo "  ffmpeg 7.1 已装，跳过编译"
if ! grep -q "8\.5" "$PREFIX/lib/pkgconfig/libcurl.pc" 2>/dev/null || [ ! -s "$PREFIX/lib/pkgconfig/libcurl.pc" ]; then
  [ -d curl-8.5.0 ] || { curl -sL -o curl-8.5.0.tar.gz https://curl.se/download/curl-8.5.0.tar.gz && tar xzf curl-8.5.0.tar.gz; }
  # 坏掉的 .pc 会让 curl 自己的 configure 读到空文件而失败；重建前先删掉，
  # 并且这一步不让前缀的 PKG_CONFIG_PATH 参与（curl 用它自己源码树里的配置）
  rm -f "$PREFIX/lib/pkgconfig/libcurl.pc"
  ( cd curl-8.5.0 && env -u PKG_CONFIG_PATH "$CMAKE_BIN/cmake" -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_CURL_EXE=OFF \
      -DCURL_USE_OPENSSL=OFF -DCURL_ENABLE_SSL=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
      -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBIDN2=OFF \
      -DENABLE_LDAP=OFF -DCURL_DISABLE_LDAP=ON -DUSE_NGHTTP2=OFF -DUSE_LIBSSH=OFF \
      >/dev/null && "$CMAKE_BIN/cmake" --build build --parallel 8 >/dev/null && "$CMAKE_BIN/cmake" --install build >/dev/null )
  for f in "$PREFIX"/lib/libcurl.so*; do [ -e "$f" ] && ln -sf "$f" "$PREFIX/lib/x86_64-linux-gnu/"; done
  # ⚠️ 不能 sed 读同一个文件又写回同一个文件：`>` 会先截断它，sed 就读到空 → 产出 0 字节 .pc
  if [ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]; then
    sed -e "s|^prefix=.*|prefix=$PREFIX|" -e "s|^libdir=.*|libdir=\${prefix}/lib|" \
      "$PREFIX/lib/pkgconfig/libcurl.pc" > "$PREFIX/lib/pkgconfig/libcurl.pc.tmp"
    mv "$PREFIX/lib/pkgconfig/libcurl.pc.tmp" "$PREFIX/lib/pkgconfig/libcurl.pc"
  fi
fi
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --modversion libcurl

# ---- 7. 校验 ----
step "校验"
for p in libavformat libavcodec libavutil libswscale libswresample libcurl hwloc liburing; do
  printf "  %-14s %s\n" "$p" "$(PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --modversion "$p" 2>&1 | head -1)"
done
for h in hwloc/autogen/config.h hwloc.h liburing.h liburing/compat.h curl/curl.h linux/io_uring.h linux/stat.h; do
  printf "  %-26s %s\n" "$h" "$([ -f "$PREFIX/include/$h" ] && echo ✓ || echo ✗)"
done

# ---- 8. 配置 ----
if [ "${SKIP_CONFIGURE:-0}" = "1" ]; then
  echo "SKIP_CONFIGURE=1 → 跳过重新配置（保留已编译的二进制）"
  exit 0
fi
step "cmake --preset turing-release"
cd "$REPO"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export PATH="$CUDA_ROOT/bin:$CMAKE_BIN:$PATH"
export CUDAToolkit_ROOT="$CUDA_ROOT" CUDA_HOME="$CUDA_ROOT" CMAKE_PREFIX_PATH="$PREFIX"
rm -rf build/turing-release
"$CMAKE_BIN/cmake" --preset turing-release \
  -DCMAKE_CUDA_COMPILER="$CUDA_ROOT/bin/nvcc" \
  -DCMAKE_CUDA_ARCHITECTURES=75

cat <<EOF

✅ 依赖与配置就绪。下一步：
   export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
   export LD_LIBRARY_PATH="$PREFIX/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH"
   export PATH="$CUDA_ROOT/bin:$CMAKE_BIN:\$PATH"
   cmake --build build/turing-release -j $JOBS
   （nvcc 会 OOM，所以 -j4 而不是 -j$(nproc)）
EOF