# --- 省略其他未修改部分 ---

# 删除端口规则函数
function delete_port_rule() {
    print_info "--- 删除端口规则 (仅显示 IPv4) ---"
    local managed_rules=()
    local rule_numbers=()
    local all_rules=()
    
    # 获取 ufw status numbered 的原始输出以供调试
    print_info "正在获取 UFW 规则列表 (调试信息)..."
    local ufw_status=$(sudo ufw status numbered)
    echo -e "${C_YELLOW}--- UFW 原始输出 ---${C_RESET}\n${ufw_status}\n${C_YELLOW}--- 结束 ---${C_RESET}"
    
    # 收集所有 IPv4 规则（无论是否由脚本管理）
    local awk_script='
        # 匹配以 "[数字]" 开头，不含 "(v6)"
        /^\\[[0-9]+\\]/ && !/\\(v6\\)/ {
            # 提取规则编号 (第一列的 [数字]，去掉方括号)
            rule_num = substr($1, 2, length($1)-2);
            
            # 提取规则内容 (从第一个字段后的内容开始，直到行尾)
            rule_content = $0;
            sub(/^\\[[0-9]+\\][[:space:]]+/, "", rule_content);
            
            # 检查是否包含脚本的 COMMENT_TAG
            if (rule_content ~ /'"${COMMENT_TAG}"'/) {
                # 提取端口、协议和来源 IP（如果存在）
                if (rule_content ~ /'"${COMMENT_TAG}"':port:([0-9]+):([^:]+)(:from:([^[:space:]]+))?/) {
                    match(rule_content, /'"${COMMENT_TAG}"':port:([0-9]+):([^:]+)(:from:([^[:space:]]+))?/, arr);
                    port = arr[1];
                    proto = arr[2];
                    source_ip = arr[4] ? arr[4] : "任何IP";
                    print rule_num "\t" "脚本管理: 端口 " port "/" proto " (来源: " source_ip ")";
                }
            } else {
                # 非脚本管理的规则，保留完整内容
                print rule_num "\t" rule_content;
            }
        }
    '
    
    # 将 ufw status numbered 的输出通过管道传递给 awk
    while IFS=$'\t' read -r rule_num rule_content; do
        if [[ -n "$rule_num" && -n "$rule_content" ]]; then
            all_rules+=("规则 [${rule_num}]: ${rule_content}")
            rule_numbers+=("${rule_num}")
        fi
    done < <(sudo ufw status numbered | awk "$awk_script")

    if [ ${#all_rules[@]} -eq 0 ]; then
        print_warn "没有找到任何 IPv4 端口规则。请检查 UFW 是否启用或是否有规则。"
        print_info "您可以运行 'sudo ufw status numbered' 手动检查规则。"
        press_enter_to_continue
        return
    fi

    all_rules+=("返回")
    print_info "请选择要删除的规则 (脚本管理的规则以 '脚本管理' 开头):"
    select choice in "${all_rules[@]}"; do
        if [[ "$choice" == "返回" ]]; then break; fi
        if [ -n "$choice" ]; then
            local selected_num=${rule_numbers[$((REPLY-1))]}
            print_warn "将要删除: ${choice}"
            echo -n "确认删除吗? (y/N): "
            read confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 执行删除操作并捕获输出
                local delete_output=$(echo "y" | sudo ufw delete "$selected_num" 2>&1)
                if echo "$delete_output" | grep -q "Rule deleted"; then
                    print_success "规则 [${selected_num}] 已成功删除。"
                    # 重新加载 UFW 以确保规则生效
                    print_info "正在重新加载 UFW 规则..."
                    echo "y" | sudo ufw reload || { print_error "UFW 重新加载失败！请检查规则状态。"; press_enter_to_continue; return; }
                else
                    print_error "删除规则失败。输出: ${delete_output}"
                    print_info "请检查 'sudo ufw status numbered' 的输出并确保规则编号正确。"
                fi
            else
                print_info "操作已取消。"
            fi
        else
            print_error "无效选项。"
        fi
        break
    done
    press_enter_to_continue
}

# --- 省略其他未修改部分 ---
