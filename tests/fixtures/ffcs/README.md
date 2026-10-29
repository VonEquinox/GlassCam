# FFCS 数值夹具

`ffcs-v020-stage-goldens.json` 来自固定 FFCS 0.2.0 Python 参考实现，记录输入、逐阶段结果及参考源码哈希。`ffcs_mobile_stage_goldens.json` 是旧 XH2S 编码 RGB 路径的 schema 1 阶段夹具。上游版本与归档哈希见 [FFCS 来源](../../../vendor/ffcs/ORIGIN.md)。

历史生成命令如下，使用主仓库提交 `77d2507` 中的原始脚本与当时匹配的参考资源，在研究环境的旧目录布局中运行：

```sh
python GlassCamPrototype/tools/verify_ffcs_v020.py --source GlassCamPrototype/reference_ffcs --generate
python GlassCamPrototype/tools/verify_ffcs.py --source GlassCamPrototype/reference_ffcs --generate
```

当前测试只消费冻结文件；生成过程不属于测试。迁移前原件保存在主仓库提交 `eb4e551`，可从仓库根目录恢复：

```sh
git show eb4e551:GlassCamPrototype/validation/ffcs-v020-stage-goldens.json > tests/fixtures/ffcs/ffcs-v020-stage-goldens.json
git show eb4e551:GlassCamPrototype/validation/ffcs_mobile_stage_goldens.json > tests/fixtures/ffcs/ffcs_mobile_stage_goldens.json
```

消费入口为 [FFCS 参考测试](../../numeric/test_ffcs_source.py)及其[参考支持模块](../../numeric/support/verify_ffcs_v020.py)。
