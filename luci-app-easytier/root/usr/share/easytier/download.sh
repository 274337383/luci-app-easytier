#!/bin/sh
# EasyTier Download Management
# Handles binary downloads from GitHub with proxy support

# 引入工具函数
. /usr/share/easytier/utils.sh 2>/dev/null || true

# 默认 GitHub 加速代理列表
DEFAULT_PROXYS="
https://ghproxy.net/
https://gh-proxy.com/
https://cdn.gh-proxy.com/
https://ghfast.top/
"

# 获取代理列表
# 优先从 UCI 配置读取，否则使用默认值
get_proxy_list() {
	local proxys=$(uci -q get easytier.@easytier[0].github_proxys)
	[ -z "$proxys" ] && proxys="$DEFAULT_PROXYS"
	echo "$proxys"
}

# 获取最新版本号
get_latest_version() {
	local user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
	local tag=""
	local curltest=$(which curl)
	
	if [ -z "$curltest" ] || [ ! -s "$(which curl)" ]; then
		tag=$(wget -T 5 -t 3 --user-agent "$user_agent" --max-redirect=0 --output-document=- \
			https://api.github.com/repos/EasyTier/EasyTier/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4)
		[ -z "$tag" ] && tag=$(wget -T 5 -t 3 --user-agent "$user_agent" --quiet --output-document=- \
			https://api.github.com/repos/EasyTier/EasyTier/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4)
	else
		tag=$(curl --connect-timeout 3 --user-agent "$user_agent" \
			https://api.github.com/repos/EasyTier/EasyTier/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4)
		[ -z "$tag" ] && tag=$(curl -L --connect-timeout 3 --user-agent "$user_agent" -s \
			https://api.github.com/repos/EasyTier/EasyTier/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4)
	fi
	
	# 如果获取失败，从 UCI 配置或使用默认版本
	if [ -z "$tag" ]; then
		tag=$(uci -q get easytier.@easytier[0].fallback_version)
		[ -z "$tag" ] && tag="v2.6.2"
	fi
	
	# security: tag 必须为 semver 格式 (防注入任意 URL 路径)
	case "$tag" in
	    v[0-9]*.[0-9]*.[0-9]*) ;;
	    *)
	        log_message "WARN" "easytier" "非法版本号 [$tag], 回退默认 v2.6.2" "/tmp/easytier.log"
	        tag="v2.6.2"
	        ;;
	esac

	echo "$tag"
}

# 下载二进制文件
# 参数: $1=版本号 $2=CPU架构 $3=目标路径
download_binary() {
	local tag="$1"
	local cpucore="$2"
	local path="$3"
	local proxys=$(get_proxy_list)
	local download_url="https://github.com/EasyTier/EasyTier/releases/download/${tag}/easytier-linux-${cpucore}-${tag}.zip"
	
	mkdir -p "$path"
	
	for proxy in $proxys; do
		# security: 代理地址必须为 http/https (防注入任意协议/命令)
		case "$proxy" in
		    http://*|https://*) ;;
		    *)
		        log_message "WARN" "easytier" "非法代理地址 [$proxy], 跳过" "/tmp/easytier.log"
		        continue
		        ;;
		esac
		log_message "INFO" "easytier" "尝试使用代理 ${proxy} 下载" "/tmp/easytier.log"
		
		if curl -L -o /tmp/easytier.zip --connect-timeout 10 --retry 3 "${proxy}${download_url}" || \
		   wget --timeout=10 --tries=3 -O /tmp/easytier.zip "${proxy}${download_url}"; then
			
			# security: 校验 zip 完整性 + 解压后检查 ELF 与最小体积 (防错误页/损坏/恶意文件)
			if ! unzip -t /tmp/easytier.zip >/dev/null 2>&1; then
			    log_message "ERROR" "easytier" "zip 完整性校验失败" "/tmp/easytier.log"
			    rm -f /tmp/easytier.zip
			    continue
			fi
			unzip -j -q -o /tmp/easytier.zip -d /tmp
			if [ ! -s /tmp/easytier-core ] || [ "$(stat -c %s /tmp/easytier-core 2>/dev/null)" -lt 1048576 ] || \
			   ! (head -c 4 /tmp/easytier-core | grep -q $'\x7fELF'); then
			    log_message "ERROR" "easytier" "easytier-core 非有效 ELF 二进制或体积异常, 丢弃" "/tmp/easytier.log"
			    rm -f /tmp/easytier.zip /tmp/easytier-core /tmp/easytier-cli /tmp/easytier-web /tmp/easytier-web-embed
			    continue
			fi
			chmod +x /tmp/easytier-core /tmp/easytier-cli /tmp/easytier-web /tmp/easytier-web-embed 2>/dev/null || true
			rm -rf /tmp/easytier.zip
			
			log_message "INFO" "easytier" "下载成功" "/tmp/easytier.log"
			return 0
		else
			log_message "WARN" "easytier" "${proxy}${download_url} 下载失败" "/tmp/easytier.log"
		fi
	done
	
	log_message "ERROR" "easytier" "所有代理下载均失败，请手动下载上传程序" "/tmp/easytier.log"
	return 1
}

# 检查并下载程序
# 参数: $1=程序路径 $2=目标路径 $3=CPU架构
check_and_download() {
	local easytierbin="$1"
	local path="$2"
	local cpucore="$3"
	
	# 检查程序是否存在且完整
	if [ ! -f "$easytierbin" ] || [ "$($easytierbin -h 2>&1 | wc -l)" -lt 3 ]; then
		log_message "INFO" "easytier" "$easytierbin 不存在或程序不完整，开始在线下载..." "/tmp/easytier.log"
		
		local tag=$(get_latest_version)
		log_message "INFO" "easytier" "开始在线下载${tag}版本" "/tmp/easytier.log"
		
		if download_binary "$tag" "$cpucore" "$path"; then
			# 移动下载的文件到目标位置
			if [ "$(uci -q get easytier.@easytier[0].enabled)" = "1" ]; then
				mv -f /tmp/easytier-core "${path}/" 2>/dev/null
				mv -f /tmp/easytier-cli "${path}/" 2>/dev/null
				chmod +x "$easytierbin" 2>/dev/null
			fi
			
			if [ "$(uci -q get easytier.@easytier[0].web_enabled)" = "1" ]; then
				local webbin=$(uci -q get easytier.@easytier[0].webbin)
				[ -z "$webbin" ] && webbin="/usr/bin/easytier-web"
				mv -f /tmp/easytier-web-embed "$webbin" 2>/dev/null || true
				chmod +x "$webbin" 2>/dev/null
			fi
			
			return 0
		fi
		
		return 1
	fi
	
	return 0
}

# 处理上传的程序
# 参数: $1=目标路径 $2=程序路径
handle_uploaded_binary() {
	local path="$1"
	local easytierbin="$2"
	local size=$(get_available_space "$path")
	
	if [ -f /tmp/easytier-core ] || [ -f /tmp/easytier-cli ]; then
		if [ "${path:0:4}" != "/tmp" ]; then
			chmod +x /tmp/easytier-core 2>/dev/null
			chmod +x /tmp/easytier-cli 2>/dev/null
			mkdir -p "$path"
			
			log_message "INFO" "easytier" "找到上传的程序/tmp/easytier-core，替换为$easytierbin" "/tmp/easytier.log"
			
			local upsize=$(du -k /tmp/easytier-core 2>/dev/null | cut -f1)
			local result=$((size - upsize))
			
			if [ "$(/tmp/easytier-core -h 2>&1 | wc -l)" -gt 3 ] && [ "$result" -gt 1000 ]; then
				mv -f /tmp/easytier-core "$easytierbin" 2>/dev/null
				mv -f /tmp/easytier-cli "${path}/easytier-cli" 2>/dev/null
				return 0
			else
				log_message "WARN" "easytier" "无法替换，上传的程序不完整或自定义路径的可用空间不足，当前空间剩余${size}kb" "/tmp/easytier.log"
				return 1
			fi
		fi
	fi
	
	return 1
}
