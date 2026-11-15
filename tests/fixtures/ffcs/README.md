# FFCS 数值夹具

`ffcs-v020-stage-goldens.json` 来自固定 FFCS 0.2.0 Python 参考实现，记录输入、逐阶段结果及参考源码哈希。上游版本与归档哈希见 [FFCS 来源](../../../vendor/ffcs/ORIGIN.md)。旧 0.1 版本的 XH2S 阶段证据由 `GlassCam-research` 的 `tools/studies/product-tooling/` 归档。

历史生成命令如下，使用主仓库提交 `77d2507` 中的原始脚本与当时匹配的参考资源，在研究环境的旧目录布局中运行：

```sh
python GlassCamPrototype/tools/verify_ffcs_v020.py --source GlassCamPrototype/reference_ffcs --generate
```

当前测试只消费冻结文件；生成过程不属于测试。迁移前原件保存在主仓库提交 `eb4e551`，可从仓库根目录恢复：

```sh
git show eb4e551:GlassCamPrototype/validation/ffcs-v020-stage-goldens.json > tests/fixtures/ffcs/ffcs-v020-stage-goldens.json
```

消费入口为 [FFCS 参考测试](../../numeric/test_ffcs_source.py)及其[参考支持模块](../../numeric/support/verify_ffcs_v020.py)。

## 当前原厂整数映射

`native-mapping-vectors.zip` 对应 render revision 3，SHA-256 为 `bee57df3e36a8a66ae4bf0a1dc0565bf5ef3b1bd9dfc981f2ae1e84d16fb652a`。原厂为 RFC EX 3.0／SILKYPIX 8.1.20.0，框架哈希、原始输入／输出哈希及样本索引记录在归档清单中。

夹具覆盖全部原始资源的 Normal2／Normal2Fixed 分派、`sigma = 0.5055` 和工作白值 `20000`。整数期望来自原厂实际输出；浮点输入／期望仅按原表 gamma 和标准 sRGB 传递函数转换单位，不运行产品算法。旧 FFCS 0.2.0 golden 保持不变。

在 `GlassCam-research` 中，从已保存的独立原厂数组冻结：

```sh
python tools/native-parity/freeze_production_color.py \
  --evidence "$EVIDENCE" --product "$GLASSCAM"
```

消费入口为 [原厂映射与生产浮点桥测试](../../numeric/test_ffcs_native_mapping.py)。
