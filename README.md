# 🎨 ComfyUI Docker 一键部署脚本

折腾 ComfyUI 的环境太烦了？Docker 命令记不住？显卡驱动配不好？
这个脚本专治各种部署疑难杂症，帮你一条龙搞定。不管你是刚买的 50 系新卡，还是像我一样捡垃圾用的 P102 矿卡，都能跑。

## ✨ 这玩意能干啥？

*   **全自动装环境**：没装 Docker？没配 N 卡 Toolkit？脚本全自动帮你搞定。
*   **自动认显卡**：自动识别型号，新卡老卡自动挑合适的 CUDA 镜像。
*   **不怕重装丢数据**：模型、插件、图片全存在你指定的文件夹，容器随便删，数据不丢。
*   **弄坏了能回滚**：更新失败会自动恢复旧容器，不会让你干瞪眼。
*   **中英双语**：自动识别系统语言。
*   支持debian
*   
一键部署命令curl -fsSL https://raw.githubusercontent.com/mchuazai/comfyui-mchuazai/main/install.sh -o install.sh && sudo bash install.sh
