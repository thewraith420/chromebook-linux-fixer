# Reference: the Intel IPU IOMMU passthrough quirk

**This is a reference, not an appliable patch.** It is recorded here because it
is the implementation Ubuntu ships, and because its history changes how the
`ipu3-imgu-iommu` problem should be maintained.

## Provenance, and why it matters

Posted upstream by Bingbu Cao (Intel) as *"iommu/vt-d: Use passthrough mode for
the Intel IPUs"* — v2 in April 2021, RESEND v3 in January 2023.

**It was rejected.** Baolu Lu (Intel IOMMU maintainer) declined it:

> Please don't try to fix any problem in the device driver by adding any
> hard-coded quirky code in the IOMMU code.

His position: the IPU driver's own mapping behaviour is the actual bug, and
users already have `iommu=pt` and the per-device `/sys/.../iommu_group/type`
knob. Those two remedies are exactly what this tool's `apply` and its
documented recovery step do — so the userspace side of this fix is the
upstream-sanctioned route, not a hack around a missing patch.

**Ubuntu carries the rejected patch anyway**, forward-ported, as SAUCE. That is
why a stock Ubuntu kernel places the IPU in a passthrough domain unaided while
a kernel built from mainline source does not:

| symbol | Ubuntu 7.0.0-30 | mainline-derived 7.1.9 |
|---|---|---|
| `quirk_iommu_igfx` | present | present |
| `quirk_iommu_rwbf` | present | present |
| `quirk_iommu_ipu`  | **present** | **absent** |
| `dmar_map_ipu`     | **present** | **absent** |

Practical consequence: **do not wait for mainline.** Upstream has considered
this and declined, so any mainline-derived kernel needs its own quirk carried
indefinitely, re-applied on every rebase. If it is ever silently dropped, the
machine hard locks the first time anything streams the ImgU — no panic, nothing
in the logs.

## Device IDs

v2 matched five; v3 added `0x462e`, `0xa75d`, `0x7d19`:

    0x9a19  0x9a39  0x4e19  0x465d  0x462e  0xa75d  0x7d19  0x1919

`0x1919` is the IPU3 ImgU in the Pixel Slate (Nocturne). The rest are mostly
IPU6 parts in later Intel laptops.

## The diff (v2, against a v5.12-era tree)

Recorded for the shape of the approach. **The line numbers and surrounding code
no longer match a 7.x tree** — `device_def_domain_type()`, `si_domain_init()`
and the `intel_iommu_strict` handling have all been reworked since. Anyone
adopting this is doing a port, not a copy.

```diff
--- a/drivers/iommu/intel/iommu.c
+++ b/drivers/iommu/intel/iommu.c
@@ -55,6 +55,12 @@
 #define IS_ISA_DEVICE(pdev) ((pdev->class >> 8) == PCI_CLASS_BRIDGE_ISA)
+#define IS_INTEL_IPU(pdev) ((pdev)->vendor == PCI_VENDOR_ID_INTEL && \
+	((pdev)->device == 0x9a19 || \
+	(pdev)->device == 0x9a39 || \
+	(pdev)->device == 0x4e19 || \
+	(pdev)->device == 0x465d || \
+	(pdev)->device == 0x1919))

@@ -360,6 +366,7 @@
 static int dmar_map_gfx = 1;
+static int dmar_map_ipu = 1;

@@ -368,6 +375,7 @@
 #define IDENTMAP_AZALIA 4
+#define IDENTMAP_IPU 8

@@ -2839,6 +2847,9 @@ static int device_def_domain_type(struct device *dev)
 	if ((iommu_identity_mapping & IDENTMAP_GFX) && IS_GFX_DEVICE(pdev))
 		return IOMMU_DOMAIN_IDENTITY;
+
+	if ((iommu_identity_mapping & IDENTMAP_IPU) && IS_INTEL_IPU(pdev))
+		return IOMMU_DOMAIN_IDENTITY;

@@ -3278,6 +3289,9 @@ static int __init init_dmars(void)
 	if (!dmar_map_gfx)
 		iommu_identity_mapping |= IDENTMAP_GFX;
+
+	if (!dmar_map_ipu)
+		iommu_identity_mapping |= IDENTMAP_IPU;

@@ -5622,6 +5636,18 @@ static void quirk_iommu_igfx(struct pci_dev *dev)
+static void quirk_iommu_ipu(struct pci_dev *dev)
+{
+	if (!IS_INTEL_IPU(dev))
+		return;
+
+	if (risky_device(dev))
+		return;
+
+	pci_info(dev, "Passthrough IOMMU for integrated Intel IPU\n");
+	dmar_map_ipu = 0;
+}

@@ -5657,6 +5683,9 @@
+/* disable IPU dmar support */
+DECLARE_PCI_FIXUP_HEADER(PCI_VENDOR_ID_INTEL, PCI_ANY_ID, quirk_iommu_ipu);
```

## Two details worth stealing even if you keep a narrower quirk

- **`risky_device(dev)`** — refuses the passthrough if firmware marked the
  device externally accessible (Thunderbolt/DMA-attack surface). A bespoke
  per-device quirk that omits this check silently gives up that protection.
- **It reuses the existing `dmar_map_gfx` / `IDENTMAP_GFX` mechanism** rather
  than special-casing the device, so it composes with the rest of the VT-d
  identity-mapping logic instead of sitting beside it.

## Sources

- v3 (patchew): https://patchew.org/linux/20230105082857.4180299-1-bingbu.cao@intel.com/
- v2 (lore): https://lore.kernel.org/lkml/1618886556-6412-1-git-send-email-bingbu.cao@intel.com/T/
- Ubuntu bug #1989041: https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1989041
