# Task 1: Cloning

Let’s start with creating a clone of the **LAB-RESOURCE** UCS Server Profile Template.
Go to **Configure -> Templates** on the left and select the **UCS Server Profile Templates** at the top.
Click **Three dots** on the right of LAB-Resources and select **Clone**.

![Cloning 1](./Cloning1.png "Cloning 1")

The destination Organization is X-Series-Configuration
Select “Create new clones for all policies and pools inside of the destination organization.”

![Cloning 2](./Cloning2.png "Cloning 2")

Click Next

Suffix Name for Cloned Policies and Pools should be **-SRVxx**, where **x is your pod number**.

The clone name can be SRVxx-ServerProfileTemplate, where **x is your pod number**.
Set Tags to SRV:SRVxx, **where x is your pod number**.

![Cloning 3](./Cloning3.png "Cloning 3")

Click **Clone**

This triggers a Request; you can monitor the process of the clone by clicking on the request icon and observing your request. 


![Cloning 5](./Cloning5.png "Cloning 5")

The process of creating the clone is about 10 seconds.
Now you see the new UCS Server Profile Template that you can work with.


![Cloning 4](./Cloning4.png "Cloning 4")
