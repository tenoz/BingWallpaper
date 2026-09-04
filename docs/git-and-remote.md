# 远端仓库与推送

面向接手者：本文讲**代码托管在哪、怎么推送**。
改代码时必须遵守的约定在根 `CLAUDE.md`，本文只放操作步骤与踩坑细节。

- 远端：`https://github.com/tenoz/BingWallpaper.git`（账号 `tenoz`，**私有仓库**，2026-09-03 建并首次推送）
- 默认分支：`main`

---

## 推送认证

GitHub 早已不支持用「账号密码」推送 git，需要 Personal Access Token（PAT），
就是一串 `ghp_` 开头的字符串。

### 令牌放哪

存在 `~/.github_bw_pat`（权限 600，只有本人可读）：

```bash
printf '%s' 'ghp_你的令牌' > ~/.github_bw_pat && chmod 600 ~/.github_bw_pat
```

⚠️ 当前这枚令牌**没有过期时间**（老大 2026-09-03 设为永久）。这意味着
**一旦泄露就是长期有效**——切勿写进任何文件、命令或聊天记录。
不用时删掉 `~/.github_bw_pat`，并到 <https://github.com/settings/tokens> 点 Delete 作废。

### 怎么推

**坑一：git 通道只认 Basic 认证，不认 Bearer 头。**
用 `Authorization: Bearer` 会报 `invalid credentials`。必须走 Basic：
用户名填 `x-access-token`，密码填令牌。

**坑二：必须绕过本机代理。**
开发机环境里 `http_proxy` / `https_proxy` 指向 `127.0.0.1:59218`，
git 走它会报 `CONNECT tunnel failed, response 502`（而且时好时坏，
同一时刻 curl 直连是通的，容易误判成网络问题）。

把下面这段存成脚本用即可（令牌不进 `.git/config`，远端地址保持干净）：

```bash
cat > /tmp/gh_askpass.sh <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) echo "x-access-token" ;;
  *Password*) tr -d '\n' < ~/.github_bw_pat ;;
esac
EOF
chmod 700 /tmp/gh_askpass.sh

cd /Users/pxdog/Project/BingWallpaper
env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
    GIT_ASKPASS=/tmp/gh_askpass.sh GIT_TERMINAL_PROMPT=0 \
    git push origin main
rm -f /tmp/gh_askpass.sh   # 用完即删
```

### 怎么确认真的推上去了

别只信 `Everything up-to-date` 这类提示，直接比对 SHA：

```bash
git rev-parse HEAD
git rev-parse origin/main
env http_proxy= https_proxy= ... git ls-remote --heads origin
```

三处的 SHA 一致才算推送成功。

---

## 提交规矩

**提交前必须先问老大**（2026-09-03 定，用户级记忆里也记了这条）。
给出提交信息草稿、经确认后再执行。
