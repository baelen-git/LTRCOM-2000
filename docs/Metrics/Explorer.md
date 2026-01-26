# Task 2: Explorer

Explorer is a new feature in Intersight. It will give you metrics about different devices and parameters.

During the creation of this document, the whole environment wasn’t up and running, and therefore, you don’t see much traffic/values in the following screenshots.

This Explorer feature will improve and more will be added.

On the left side, select Explorer.

![Explorer 1](./Explorer1.png "Explorer 1")

**Note**:
Keep in mind, when you have the Advantage License Tier option, the data is collected every minute, but the granularity is still at 10 min.

![Explorer 2](./Explorer2.png "Explorer 2")

For the first metrics, we are selecting:  
**Host Power and Status** -> **Host Power** -> **Maximum**

![Explorer 3](./Explorer3.png "Explorer 3")

![Explorer 4](./Explorer4.png "Explorer 4")

Click on “Group By” and select **Host Name**

Select a time interval of Last Month to see nicer graphs.

Here is the current result:

![Explorer 5](./Explorer5.png "Explorer 5")

The limit is already set to 5.

If you want to see the 8 FI set the limit to 8.

![Explorer 6](./Explorer6.png "Explorer 6")

And here is the result where you see the 8 FI’s.

![Explorer 7](./Explorer7.png "Explorer 7")

**Disable** this metric (Slide next to “**Host Power – Maximum**” and **Add Metric** for a new metric.

![Explorer 8](./Explorer8.png "Explorer 8")

Select:

* **Metrics**: **Network Interface** -> **Operational Link Speed** -> **Maximum**
* **Filter By**: Host Type equals Fabric Interconnect
* **Group By**: Host Name
* **Limit**: 5

![Explorer 9](./Explorer9.png "Explorer 9")

The result you see are in **Bps** (Bytes per Second.)

This is for every network related metric. Keep this in mind that it is NOT bps (bits per second.)

In this case the Max link is 25 GBps or 200 Gbps.

![Explorer 10](./Explorer10.png "Explorer 10")

To find the power usage of one chassis, you need to know the chassis identifier.

![Explorer 11](./Explorer11.png "Explorer 11")

One easy way to get this, is to go to the Chassis you want to know the details and select metrics.

On the left, go to **Operate** -> **Chassis** / Select **int-ucs-04-1** (Chassis name) / Click **Metrics**. (On the top)

Look for the **Power** with PSU1 as Endpoint.

Expand it and click on **View in Explorer**

![Explorer 12](./Explorer12.png "Explorer 12")

![Explorer 13](./Explorer13.png "Explorer 13")

Click on **Filter By** and you will see:

![Explorer 14](./Explorer14.png "Explorer 14")

The right Identifier is now chosen, but there is only one PSU and we want to have all PSUs to see the power consumption of the chassis.

**Remove** the **Name = PSU1** and type in that field **Name**. Then select name and select **contains**.

![Explorer 15](./Explorer15.png "Explorer 15")

Instead of choosing a PSU from the list, type **PSU** and hit enter.

![Explorer 16](./Explorer16.png "Explorer 16")

Now you see the power consumption of the total chassis.
If you select a time interval of one week, you can see that we had issues in the lab.

![Explorer 17](./Explorer17.png "Explorer 17")

![Explorer 18](./Explorer18.png "Explorer 18")