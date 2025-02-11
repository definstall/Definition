#!/bin/bash

# Nginx主配置文件路径
nginx_main_conf_path="/etc/nginx/nginx.conf"
# Nginx域名配置文件路径
nginx_domain_conf_path="/etc/nginx/conf.d/nginx.conf"

# 红色文字输出
function Echo_Red() {
    echo -e "\033[31m$1\033[0m"
}

# 检查系统是否为Ubuntu，如果不是则退出脚本
function checkUbuntu() {
    if [[ "$(uname -s)" != "Linux" || ! -e "/etc/os-release" || "$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2)" != "ubuntu" ]]; then
        Echo_Red "错误：该脚本仅适用于Ubuntu系统。退出。"
        exit 1
    fi
}

# 检查Nginx是否安装
function checkNginx() {
    if command -v nginx &> /dev/null; then
        nginx_version=$(nginx -v 2>&1 | awk -F '/' 'NR==1{print $2}')
        if [ $? -eq 0 ]; then
            Echo_Red "Nginx 已安装，版本：$nginx_version"
        else
            Echo_Red "无法获取 Nginx 版本信息。"
        fi
    else
        Echo_Red "Nginx 未安装。"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 安装Nginx
function installNginx() {
    if ! command -v nginx &> /dev/null; then
        Echo_Red "安装 Nginx..."
        sudo apt-get update && sudo apt-get install -y nginx npm
        sleep 2
        # 2. 检测并安装/更新 PM2
        echo "检查 PM2 是否安装..."
        if command_exists pm2; then
            echo "PM2 已安装，正在更新 PM2..."
            sudo npm install -g pm2
        else
            echo "PM2 未安装，正在安装 PM2..."
            sudo npm install -g pm2
        fi

        # 确保 PM2 安装或更新成功
        if ! command_exists pm2; then
            echo "PM2 安装或更新失败，请检查 npm 配置。"
            sleep 3  # 暂停3秒
        fi

        # 3. 禁用 PM2 的自动启动功能
        echo "禁用 PM2 的自动启动功能..."
        pm2 unstartup

        # 4. 停止所有 PM2 进程
        echo "停止所有 PM2 进程..."
        pm2 stop all
        pm2 delete all


        # 检查是否有gzip配置   配置 ngxin config.conf
        if grep -q "gzip on;" $nginx_main_conf_path; then
            # 在gzip on;行之后添加gzip配置            client_max_body_size 500m;
           # sudo sed -i '/gzip on;/a \\tclient_max_body_size 500m;\n\gzip_buffers 16 8k;\n\tgzip_comp_level 6;\n\tgzip_http_version 1.1;\n\tgzip_min_length 256;\n\tgzip_proxied any;\n\tgzip_vary on;\n\tgzip_types text/xml application/xml application/atom+xml application/rss+xml application/xhtml+xml image/svg+xml text/javascript application/javascript application/x-javascript text/x-json application/json application/x-web-app-manifest+json text/css text/plain text/x-component font/opentype font/ttf application/x-font-ttf application/vnd.ms-fontobject image/x-icon;\n\tgzip_disable "MSIE [1-6]\\.(?!.*SV1)";' $nginx_main_conf_path
        sudo sed -i '/gzip on;/a \\t#该指令用于开启或关闭gzip模块(on/off)\n\tgzip_buffers 16 8k;\n\t#设置系统获取几个单位的缓存用于存储gzip的压缩结果数据流。16 8k代表以8k为单位，安装原始数据大小以8k为单位的16倍申请内存\n\tgzip_comp_level 6;\n\t#gzip压缩比，数值范围是1-9，1压缩比最小但处理速度最快，9压缩比最大但处理速度最慢\n\tgzip_http_version 1.1;\n\t#识别http的协议版本\n\tgzip_min_length 256;\n\t#设置允许压缩的页面最小字节数，页面字节数从header头得content-length中进行获取。默认值是0，不管页面多大都压缩。这里我设置了为256\n\tgzip_proxied any;\n\t#这里设置无论header头是怎么样，都是无条件启用压缩\n\tgzip_vary on;\n\t#在http header中添加Vary: Accept-Encoding ,给代理服务器用的\n\tgzip_types\n\t\ttext/xml application/xml application/atom+xml application/rss+xml application/xhtml+xml image/svg+xml\n\t\ttext/javascript application/javascript application/x-javascript\n\t\ttext/x-json application/json application/x-web-app-manifest+json\n\t\ttext/css text/plain text/x-component\n\t\tfont/opentype font/ttf application/x-font-ttf application/vnd.ms-fontobject\n\t\timage/x-icon;\n\t#进行压缩的文件类型,这里特别添加了对字体的文件类型\n\tgzip_disable "MSIE [1-6]\\.(?!.*SV1)";\n\t#禁用IE 6 gzip\n\t\n\t' $nginx_main_conf_path

        else
            # 在http {之后添加gzip配置
            sudo sed -i '/http {/a \\tclient_max_body_size 500m;\n\gzip on;\n\tgzip_buffers 16 8k;\n\tgzip_comp_level 6;\n\tgzip_http_version 1.1;\n\tgzip_min_length 256;\n\tgzip_proxied any;\n\tgzip_vary on;\n\tgzip_types text/xml application/xml application/atom+xml application/rss+xml application/xhtml+xml image/svg+xml text/javascript application/javascript application/x-javascript text/x-json application/json application/x-web-app-manifest+json text/css text/plain text/x-component font/opentype font/ttf application/x-font-ttf application/vnd.ms-fontobject image/x-icon;\n\tgzip_disable "MSIE [1-6]\\.(?!.*SV1)";' $nginx_main_conf_path
        fi
    else
        Echo_Red "Nginx 已安装。"
    fi
    sleep 2
}

# 卸载Nginx
function uninstallNginx() {
    if command -v nginx &> /dev/null; then
        Echo_Red "卸载 Nginx..."
        sudo apt-get remove --purge -y nginx nginx-common nginx-core npm
        sudo apt-get autoremove -y
        sudo rm -rf /etc/nginx/
        Echo_Red "Nginx 已卸载并清除相关文件。"
    else
        Echo_Red "Nginx 未安装。"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 检查/安装/卸载 Nginx 子菜单
function manageNginx() {
    clear
    Echo_Red "Nginx 管理子菜单"
    Echo_Red "============================================"
    echo "1. 检查 Nginx 安装状态"
    echo "2. 安装 Nginx"
    echo "3. 卸载 Nginx"
    echo "4. 返回主菜单"
    Echo_Red "============================================"
    read -r -p "请输入选项（1-4）: " sub_option

    case $sub_option in
        1)
            checkNginx
            ;;
        2)
            installNginx
            ;;
        3)
            uninstallNginx
            ;;
        4)
            main
            ;;
        *)
            Echo_Red "无效选项，请重新输入。"
            read -n 1 -s -r -p "按任意键继续..."
            ;;
    esac
    manageNginx
}

function checkDomainExists() {
    local domain="$1"  # 从函数参数中获取域名
    # 检查配置文件中是否包含指定的域名
    if ! grep -q "server_name $domain;" "$nginx_domain_conf_path"; then
        return 1  # 返回 1 表示未找到该域名
    fi
    return 0  # 返回 0 表示域名存在
}

# 查看Nginx配置文件中的域名和端口
function viewNginxConfig() {
    if [ ! -f "$nginx_domain_conf_path" ]; then
        Echo_Red "配置文件不存在：$nginx_domain_conf_path"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if grep -q "server_name" "$nginx_domain_conf_path"; then
        Echo_Red "已有的域名和端口:"
        awk '/server_name/ {
            domain = $2;
            sub(/;/, "", domain);
            domain_list[++count] = domain;
        } /proxy_pass http:\/\/127.0.0.1:([0-9]+);/ {
            split($0, arr, ":");
            port = substr(arr[3], 1, length(arr[3])-1);
            port_list[count] = port;
        } END {
            for (i = 1; i <= count; i++) {
                print i ": " domain_list[i] " 端口：" port_list[i];
            }
        }' "$nginx_domain_conf_path"
    else
        Echo_Red "配置文件中未找到server_name项。"
    fi
    read -n 1 -s -r -p "按任意键继续..."
}

# 用户交互添加域名和端口到Nginx配置文件
function addDomainPort() {
    [ ! -f "$nginx_domain_conf_path" ] && sudo touch "$nginx_domain_conf_path"

    Echo_Red "请输入域名（例如：example.com）："
    read -r domain
    Echo_Red "请输入端口号："
    read -r port


    # 检查域名是否在配置文件中
    checkDomainExists "$domain"
    if [[ $? -ne 1 ]]; then  # 如果返回值不为0（表示没有找到域名），则退出
        Echo_Red "已经有该域名配置！"
        sleep 3  # 暂停3秒
        return
    fi
  
    # 验证域名和端口
    if ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        Echo_Red "域名格式无效。"
        sleep 3  # 暂停3秒
        return
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ] || [ "$port" -gt 65535 ]; then
        Echo_Red "端口号无效。"
        sleep 3  # 暂停3秒
        return
    fi

    # 在配置文件末尾添加新的server块
    echo -e "\nserver {" >> "$nginx_domain_conf_path"
    echo -e "  listen 80;" >> "$nginx_domain_conf_path"
    echo -e "  server_name $domain;" >> "$nginx_domain_conf_path"
    echo -e "    \n" >> "$nginx_domain_conf_path"
    echo -e "    client_body_timeout 120s; # 设置客户端请求超时时间" >> "$nginx_domain_conf_path"
    echo -e "    send_timeout 120s; # 设置 keep-alive 超时时间" >> "$nginx_domain_conf_path"
    echo -e "    keepalive_timeout 65s;  # 可以根据需求调整，例如 60s、120s 等" >> "$nginx_domain_conf_path"
    echo -e "    keepalive_requests 100;  # 每个连接最多允许 100 个请求" >> "$nginx_domain_conf_path"
    echo -e "    \n" >> "$nginx_domain_conf_path"
    echo -e "\n  location / {" >> "$nginx_domain_conf_path"
    echo -e "    proxy_pass http://127.0.0.1:$port;" >> "$nginx_domain_conf_path"
    echo -e "    proxy_set_header Host \$host;" >> "$nginx_domain_conf_path"
    echo -e "    proxy_set_header X-Real-IP \$remote_addr;" >> "$nginx_domain_conf_path"
    echo -e "    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" >> "$nginx_domain_conf_path"
    echo -e "    client_max_body_size 200m;" >> "$nginx_domain_conf_path"
    echo -e "    }" >> "$nginx_domain_conf_path"
    echo -e "    \n" >> "$nginx_domain_conf_path"
    echo -e "    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {" >> "$nginx_domain_conf_path"
    echo -e "    expires 30d;" >> "$nginx_domain_conf_path"
    echo -e "    add_header Cache-Control "public";" >> "$nginx_domain_conf_path"
    echo -e "    add_header Last-Modified $date_gmt;" >> "$nginx_domain_conf_path"
    echo -e "    add_header ETag "W/\"$content_length-$mtime\"";" >> "$nginx_domain_conf_path"
    echo -e "    }" >> "$nginx_domain_conf_path"
    echo -e "    \n" >> "$nginx_domain_conf_path"
    # 防止爬虫抓取 防止爬虫抓取可能会对网站的SEO产生一定的影响，具体取决于你选择的实现方式和执行策略
    echo -e " if (\$http_user_agent ~* \"360Spider|JikeSpider|Spider|spider|bot|Bot|2345Explorer|curl|wget|webZIP|qihoobot|Baiduspider|Googlebot|Googlebot-Mobile|Googlebot-Image|Mediapartners-Google|Adsbot-Google|Feedfetcher-Google|Yahoo! Slurp|Yahoo! Slurp China|YoudaoBot|Sosospider|Sogou spider|Sogou web spider|MSNBot|ia_archiver|Tomato Bot|NSPlayer|bingbot\") {" >> "$nginx_domain_conf_path"
    echo -e "      return 403;" >> "$nginx_domain_conf_path"
    echo -e "  }\n}" >> "$nginx_domain_conf_path"
    restartnginx
    Echo_Red "域名和端口已成功添加到Nginx配置文件。"
    read -n 1 -s -r -p "按任意键继续..."
}

# 删除指定域名的服务器块
function deleteDomainPort() {
    # 检查配置文件是否存在
    [ ! -f "$nginx_domain_conf_path" ] && { 
        Echo_Red "配置文件不存在：$nginx_domain_conf_path"; 
        read -n 1 -s -r -p "按任意键继续..."; 
        return; 
    }

    # 查看当前的 Nginx 配置
    viewNginxConfig

    echo
    Echo_Red "请输入要删除的域名（例如：example.com），或输入 'c' 取消:"
    read -r domain_name

    # 如果输入 'c' 则取消删除操作
    if [[ "$domain_name" == "c" ]]; then
        Echo_Red "取消删除，未做任何改变。"
    else
        # 获取包含指定域名的 server_name 行的行号
        line_number=$(awk -v domain="$domain_name" '$0 ~ ("server_name " domain ";") {print NR}' "$nginx_domain_conf_path")

        # 检查是否找到匹配的内容
        if [[ -n "$line_number" ]]; then
            # 获取开始和结束行的行号（这里假设删除指定域名的上2行和下8行）
            start=$((line_number - 2))  # 删除之前的两行（如 listen 和 server_name）
            end=$((line_number + 12))    # 删除之后的 8 行（包括可能的 location 配置）

            # 使用 awk 删除指定范围的行
            awk -v start="$start" -v end="$end" 'NR < start || NR > end' "$nginx_domain_conf_path" > temp_config && mv temp_config "$nginx_domain_conf_path"

            # 重启 Nginx 服务以应用修改
            restartNginx

            Echo_Red "域名和端口已成功删除：$domain_name"
        else
            Echo_Red "找不到对应域名的配置，未做任何改变。"
        fi
    fi

    read -n 1 -s -r -p "按任意键继续..."
}


# 重启Nginx 2
function restartnginx() {
    checkUbuntu
    sudo service nginx restart
}

# 重启Nginx
function restartNginx() {
    checkUbuntu
    sudo service nginx restart
    Echo_Red "Nginx已成功重启。"
    read -n 1 -s -r -p "按任意键继续..."
}

# 查看Nginx运行状态
function checkNginxStatus() {
    checkUbuntu
    sudo service nginx status
    read -n 1 -s -r -p "按任意键继续..."
}

# 主菜单
function main() {
    checkUbuntu
    while true; do
        clear
        Echo_Red "Nginx 配置管理脚本"
        Echo_Red "============================================"
        echo "1. 检查/安装/卸载 Nginx"
        echo "2. 查看 Nginx 域名和端口"
        echo "3. 添加域名和端口"
        echo "4. 删除域名和端口"
        echo "5. 重启 Nginx"
        echo "6. 查看 Nginx 运行状态"
        echo "7. 退出 Nginx 管理脚本"
        Echo_Red "============================================"
        read -r -p "请输入选项（1-7）: " option

        case $option in
            1)
                manageNginx
                ;;
            2)
                viewNginxConfig
                ;;
            3)
                addDomainPort
                ;;
            4)
                deleteDomainPort
                ;;
            5)
                restartNginx
                ;;
            6)
                checkNginxStatus
                ;;
            7)
                Echo_Red "退出 Nginx 管理脚本。"
                exit 0
                ;;
            *)
                Echo_Red "无效选项，请重新输入。"
                read -n 1 -s -r -p "按任意键继续..."
                ;;
        esac
    done
}

# 启动主菜单
main
