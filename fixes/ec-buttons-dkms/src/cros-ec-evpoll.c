// SPDX-License-Identifier: GPL-2.0
/*
 * cros-ec-evpoll - poll the Chrome EC event FIFO when the IRQ never fires.
 *
 * On some Chrome EC convertibles (confirmed: Google Nocturne / Pixel Slate) the
 * EC never delivers MKBP events to the AP after boot: the interrupt fires once
 * at startup and never again, and the ACPI notify path is dead too. Volume
 * buttons, the sensor FIFO and the lid angle all go silent even though the EC's
 * own console proves the events are happening.
 *
 * The in-tree driver's threaded IRQ handler, cros_ec_irq_thread(), is exported
 * and does nothing but drain-and-notify the FIFO. This module simply calls it
 * on a periodic workqueue instead of waiting for an interrupt that will never
 * come, so every existing MKBP consumer (buttons, sensor hub, lid) works again.
 *
 * It is a standalone add-on: it does not patch or replace cros_ec, and touches
 * no private struct layout, so it builds against any kernel that exports
 * cros_ec_irq_thread. It is the out-of-tree equivalent of kernel patch 9201;
 * load only where the EC's async path is genuinely dead, or it will race a
 * working driver for events.
 */

#include <linux/device.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

#include <linux/platform_data/cros_ec_proto.h>

/* Exported by the cros_ec module; not declared in a public header. */
irqreturn_t cros_ec_irq_thread(int irq, void *data);

static int poll_ms = 40;
module_param(poll_ms, int, 0644);
MODULE_PARM_DESC(poll_ms, "EC event FIFO poll period in milliseconds (default 40)");

static struct cros_ec_device *ec_dev;
static struct device *host_dev;		/* the cros-ec-dev we hold a ref on */
static struct delayed_work poll_work;
static struct notifier_block pm_nb;
static bool suspended;

static void evpoll_work(struct work_struct *work)
{
	if (!suspended)
		cros_ec_irq_thread(0, ec_dev);

	if (!suspended && poll_ms > 0)
		schedule_delayed_work(&poll_work, msecs_to_jiffies(poll_ms));
}

static int evpoll_pm(struct notifier_block *nb, unsigned long action, void *ptr)
{
	switch (action) {
	case PM_SUSPEND_PREPARE:
	case PM_HIBERNATION_PREPARE:
		suspended = true;
		cancel_delayed_work_sync(&poll_work);
		break;
	case PM_POST_SUSPEND:
	case PM_POST_HIBERNATION:
		suspended = false;
		if (poll_ms > 0)
			schedule_delayed_work(&poll_work, msecs_to_jiffies(poll_ms));
		break;
	}
	return NOTIFY_OK;
}

static int match_cros_ec_dev(struct device *dev, const void *data)
{
	return dev->driver && !strcmp(dev->driver->name, "cros-ec-dev");
}

static int __init evpoll_init(void)
{
	struct cros_ec_dev *ec;
	struct device *dev;

	/* Find the bound cros-ec-dev and reach its underlying EC device. */
	dev = bus_find_device(&platform_bus_type, NULL, NULL, match_cros_ec_dev);
	if (!dev) {
		pr_info("cros-ec-evpoll: no cros-ec-dev found; is cros_ec loaded?\n");
		return -ENODEV;
	}

	ec = dev_get_drvdata(dev);
	if (!ec || !ec->ec_dev) {
		put_device(dev);
		return -ENODEV;
	}

	host_dev = dev;			/* keep the reference for the module's life */
	ec_dev = ec->ec_dev;

	INIT_DELAYED_WORK(&poll_work, evpoll_work);
	pm_nb.notifier_call = evpoll_pm;
	register_pm_notifier(&pm_nb);

	if (poll_ms > 0)
		schedule_delayed_work(&poll_work, msecs_to_jiffies(poll_ms));

	pr_info("cros-ec-evpoll: polling EC event FIFO every %d ms\n", poll_ms);
	return 0;
}

static void __exit evpoll_exit(void)
{
	unregister_pm_notifier(&pm_nb);
	cancel_delayed_work_sync(&poll_work);
	put_device(host_dev);
	pr_info("cros-ec-evpoll: stopped\n");
}

module_init(evpoll_init);
module_exit(evpoll_exit);

MODULE_DESCRIPTION("Poll the Chrome EC event FIFO when its IRQ never fires");
MODULE_AUTHOR("chromebook-linux-fixer");
MODULE_LICENSE("GPL");
