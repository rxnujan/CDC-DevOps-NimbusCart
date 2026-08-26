# NimbusCart — Report

## Stack choice
REST API implemented in **Flask** (Python), per the assignment's "student's choice" clause.

## Task A — Manual peering exercise

> This section documents the expected, reasoned answer for the manual two-VPC
> peering exercise. Actually building and tearing down the throwaway VPCs is a
> hands-on step you should run yourself and capture your own console
> screenshots/terminal output for, since that evidence has to come from a
> real session in your own AWS account.

**Q1: What happens if you forget the return route in data-vpc's route table?**

The connection breaks in one direction only. If app-vpc's route table has a
route to data-vpc's CIDR via the peering connection, but data-vpc's route
table has no route back to app-vpc's CIDR, then:
- A TCP SYN sent from the app tier reaches the DB subnet (the peering
  connection carries it, and there's an inbound security group rule
  allowing it).
- The DB instance's SYN-ACK has nowhere to go — data-vpc's route table
  doesn't know how to reach app-vpc's CIDR, so the return packet is
  dropped locally.
- From the app tier's perspective this looks like a hang/timeout, not an
  immediate refusal — the initial packet leaves fine, but no response ever
  arrives. `telnet <db-ip> 5432` or `nc -zv <db-ip> 5432` would hang until
  it times out.

The direction that breaks is the **return path (data-vpc → app-vpc)**, even
though the symptom appears in the direction of the *forward* connection
attempt.

**Q2: Why does the DB subnet need no NAT Gateway, even though it must be reachable from another VPC?**

"Reachable from" and "can initiate connections to" are different things:

- **Reachable from app-vpc**: satisfied purely by the VPC peering
  connection plus route table entries plus security group rules. Peering
  is a private, non-transitive network path — it requires no NAT, no IGW,
  and no public IP on either side. The DB only needs to *receive*
  connections initiated by the app tier.
- **Can initiate connections to the internet**: this is what NAT Gateways
  and Internet Gateways are for — giving *outbound-initiated* traffic from
  a private subnet a way to reach the public internet and get responses
  back. The DB tier never needs to initiate anything outbound (no package
  installs, no external API calls), so this capability is simply
  unnecessary here.

Because the DB only ever needs to be dialed *into* over a private peering
link, and never needs to dial *out* anywhere, the data-vpc can be fully
isolated — no IGW, no NAT Gateway — while still being reachable by the
app tier.

---

## Task C — Conceptual Questions

**1. Why must the DB subnet group span multiple AZs even for a single-AZ RDS instance? What breaks if it doesn't?**

AWS requires an RDS DB subnet group to contain subnets in at least two
Availability Zones as a structural precondition, independent of whether
Multi-AZ is enabled on the instance itself. This exists because:
- It guarantees a failover target is always available if you later
  enable Multi-AZ, without needing to redefine networking.
- RDS maintenance and AZ-level recovery operations rely on being able to
  place a replacement instance in a different AZ if the original AZ has
  a problem.

If the subnet group only spans one AZ, `terraform apply` / the RDS API
call fails at creation time with a validation error — the DB subnet group
itself cannot be created with subnets in only one AZ, regardless of
whether you intend to use Multi-AZ or not.

**2. Contrast VPC Peering with a Transit Gateway for this use case. At what point would you recommend switching?**

VPC Peering:
- One-to-one, non-transitive connection between exactly two VPCs.
- No extra hourly resource cost beyond data transfer.
- Route tables must be managed by hand in every VPC involved.
- Fine for a small, fixed number of VPCs (here: exactly two).

Transit Gateway:
- Hub-and-spoke: one central resource that many VPCs attach to.
- Adds an hourly charge per attachment plus a per-GB processing fee.
- Centralizes routing — new VPCs attach without every existing VPC
  needing a new peering connection and new routes.
- Supports transitive routing (VPC A can reach VPC C through the hub
  without a direct peering connection to C).

For NimbusCart's two-VPC topology, peering is simpler and cheaper and is
the right choice. I'd recommend switching to Transit Gateway once the
number of VPCs that need to talk to each other grows past a handful (the
point where the number of pairwise peering connections — which grows as
n(n-1)/2 — becomes harder to manage than a single hub), or once transitive
routing between VPCs becomes a real requirement rather than a nice-to-have.

**3. How does the app tier's user_data authenticate to ECR and pull the image, given no public IP and no NAT route of its own?**

The app tier's route table has a `0.0.0.0/0` route pointing at the
**shared NAT Gateway** that lives in the public subnet (not a NAT Gateway
of its own — the architecture explicitly shares one NAT Gateway across the
private subnet). The sequence in `user_data_app.sh.tpl` is:

1. `aws ecr get-login-password` calls the ECR API over HTTPS (443).
   That outbound HTTPS request leaves the app tier's private subnet,
   hits the private route table's `0.0.0.0/0 → NAT Gateway` route, is
   source-NATed to the NAT Gateway's Elastic IP, and reaches ECR's public
   endpoint. The instance never needs a public IP of its own — only
   outbound-initiated traffic needs to leave, and NAT handles the return
   path because NAT Gateways (like security groups) are stateful.
2. Authentication itself doesn't use static credentials baked into
   user_data — the instance has an **IAM instance profile**
   (`aws_iam_instance_profile.app_profile`) attached, so the AWS CLI on
   the instance picks up temporary credentials automatically from the
   instance metadata service. Those credentials are scoped by the
   `AmazonEC2ContainerRegistryReadOnly` policy attached to the role.
3. `docker pull` then talks to the ECR registry, again routed outbound
   through the same NAT Gateway.

**4. Security groups are stateful, NACLs are not — give a concrete scenario where that distinction bites you here.**

Consider the app tier ↔ RDS path. The `db-sg` security group allows
inbound TCP 5432 from the app subnet's CIDR. Because security groups are
stateful, that's the *only* rule needed — the return traffic (RDS's
response to a query) is automatically permitted back out, even though
there's no explicit egress rule mentioning port 5432 or the app subnet.

If you tried to enforce the same restriction with a **NACL** on the DB
subnet instead, you'd need two rules: an inbound rule allowing 5432 from
the app subnet, **and** a separate outbound rule allowing the ephemeral
port range (typically 1024–65535) back to the app subnet, since NACLs are
stateless and evaluate each direction independently. Forgetting the
ephemeral-port outbound rule is a classic mistake: connections would
appear to establish (the SYN gets through) but then hang, because the
DB's response packets get silently dropped by the NACL on the way out.
That's exactly the kind of "looks like it should work, actually times
out" bug the SG/NACL statefulness distinction causes when someone
tightens NACLs without accounting for it.

**5. Why are local-exec provisioners discouraged in production Terraform? Why is it acceptable here?**

Terraform's core value proposition is a declarative model where the state
file accurately reflects real infrastructure, and `plan` can diff desired
vs. actual state. A `local-exec` provisioner runs an arbitrary shell
command on the machine running Terraform — Terraform has **no visibility
into what that command actually did**. It can't diff the result, doesn't
know what resources (if any) were created or mutated, can't detect drift
if the command's effects change later, and can't roll the action back on
`terraform destroy` (there's no matching "undo" — you'd need to write that
yourself as a separate provisioner). If the command is non-idempotent,
re-running `apply` can silently re-execute side effects that shouldn't
happen twice.

In this assignment, `local-exec` is used only for the Docker build/push
step (`null_resource.build_and_push_image`). That's acceptable because:
- The action has a natural idempotency guard built in — retagging and
  re-pushing the same image to the same tag is safe to repeat.
- Its result (an image sitting in ECR) is *not itself tracked as
  Terraform-managed state* — nothing downstream depends on Terraform
  knowing the image's internal contents, only on the image existing at a
  known ECR URL, which is what `aws_ecr_repository.api_repo` (a real,
  tracked resource) already gives us.
- There's no declarative Terraform resource for "build a Docker image
  and push it," so some form of imperative escape hatch is unavoidable
  for this one step — the alternative is a manual, undocumented step
  outside Terraform entirely, which is worse.

**6. Why does backend.tf deliberately not live in the same state it configures? What bootstrapping problem is being avoided?**

`backend.tf` points Terraform at an S3 bucket and DynamoDB table for
remote state storage and locking. If the *creation* of that same S3
bucket and DynamoDB table were also managed inside the state file that
lives *in* that S3 bucket, you get a chicken-and-egg problem:

- On the very first `terraform init`/`apply`, the backend doesn't exist
  yet, so there's nowhere to store the state that would record having
  created the backend.
- On `terraform destroy`, destroying the S3 bucket/DynamoDB table while
  the state file describing that destroy operation is itself stored in
  that same bucket risks corrupting or losing the state mid-operation.

The fix is to provision the S3 bucket and DynamoDB table **once, out of
band** (a small one-time `aws s3api` / `aws dynamodb create-table` step,
or a separate bootstrap Terraform configuration with its own local or
different remote state), and only then point this project's `backend.tf`
at those already-existing resources. This is called out explicitly as a
prerequisite at the top of `terraform/backend.tf` in this repo.

---

## Notes on required outputs

`terraform/outputs.tf` exposes exactly the six required outputs:
`web_public_ip`, `app_private_ip`, `db_endpoint`, `peering_connection_id`,
`nat_gateway_public_ip`, and `frontend_url`.

## What still needs to happen on your machine

This repo contains the complete application code and infrastructure-as-code.
To actually stand it up and get real evidence for your report:

1. Bootstrap the S3 + DynamoDB backend (see comment block at the top of
   `terraform/backend.tf`).
2. Set `TF_VAR_db_password`, `TF_VAR_key_pair_name`, and
   `TF_VAR_private_key_path` (or a `terraform.tfvars` you don't commit).
3. Run `./script.sh` from the repo root.
4. Capture your own terminal output and AWS console screenshots from that
   run — those are the genuine evidence a report needs, and only you can
   produce them since they come from your account and your session.
