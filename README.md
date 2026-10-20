# 星塔旅人（国服）反和谐包 v2.0

适配游戏版本 **2.0.0**。面向玩家的一键安装包，解压即用，不依赖网络。

## 下载

到 [Releases](../../releases/latest) 下载 `ssmod_v2.0.zip`（约 1.1 GB），解压后运行 `install.bat`。

镜像下载（任选其一，直连不通时用）：

- `https://ghproxy.net/https://github.com/stephen0128123-coder/xtlr-uncensor/releases/latest/download/ssmod_v2.0.zip`
- `https://ghfast.top/https://github.com/stephen0128123-coder/xtlr-uncensor/releases/latest/download/ssmod_v2.0.zip`

## v2.0 更新内容

- 修复：v1.1 在 2.0.0 版本下不生效的问题
- 修复：部分角色与 NPC 立绘显示异常
- 重新适配 2.0.0 新增的角色美术资源

## 安装

1. 完全退出游戏
2. 解压后双击 `install.bat`
3. 按提示确认游戏目录（一般会自动找到）
4. 装完直接双击游戏目录里的 `xtlr.exe` 启动

卸载：双击 `uninstall.bat`。

## 常见问题

**Q：更新游戏后失效了？**
A：游戏更新会覆盖模组文件，重新运行一次 `install.bat` 即可。如果新版游戏改了资源结构，需要等新版本模组。

**Q：装完立绘空白 / 不显示？**
A：先 `uninstall.bat` 退回国服原版，再重新 `install.bat`。仍不行请反馈。

**Q：备份目录能删吗？**
A：不能。`_uncensor_backup_<时间戳>` 里存的是国服原版文件，删了就无法一键还原。

## 版本对照

| 模组版本 | 适配游戏版本 | 资源包数 |
|---|---|---|
| v2.0 | 2.0.0 | 128 |
| v1.1 | 1.13.0 | 132 |
| v1.0 | 1.13.0 | 132 |

### v1.1（1.13.0 时代）

- 修复：部分角色过剧情时立绘不显示（NPC 立绘同样受影响）
- 修正 5 个资源包的安装位置，使其在两个安装目录中版本一致
