from datetime import UTC, datetime, timedelta

import pytest
from fastapi import HTTPException

from truckmaps.core import plans
from truckmaps.core.plans import Limits

NOW = datetime(2026, 11, 13, 12, 0, tzinfo=UTC)


def test_addons_raise_plan_limits(database):
    with database.session() as db:
        plan = plans.assign(
            db, "owner.fleet", company_id="c1", billing="annual", addons={"driver": 3, "trailer": 2}
        )

        limits = plans.limits_of(plan)

    assert (limits.drivers, limits.vehicles, limits.trailers, limits.office) == (13, 10, 12, 3)


def test_paid_plan_without_payment_falls_back_after_10_days(database):
    with database.session() as db:
        plan = plans.assign(db, "driver.pro", subject="ola", billing="monthly", moment=NOW)
        assert plan.payment_due == NOW + timedelta(days=10)
        assert not plans.is_overdue(plan, NOW + timedelta(days=9))
        assert plans.overdue(db, NOW + timedelta(days=9)) == []

        plan.payment_due = datetime.now(UTC) - timedelta(seconds=1)  # termin minął
        db.commit()

        assert plans.is_overdue(plan)
        assert plans.limits_of(plan) == plans.PLANS["driver.start"]
        assert [p.subject for p in plans.overdue(db)] == ["ola"]

        paid = plans.assign(db, "driver.pro", subject="ola", billing="monthly", paid=True)
        assert paid.payment_due is None and not plans.is_overdue(paid)
        assert plans.limits_of(paid).vehicles == 3


def test_free_plan_has_no_payment_deadline(database):
    with database.session() as db:
        plan = plans.assign(db, "driver.start", subject="jan", billing="annual")

    assert plan.payment_due is None and plan.billing is None


def test_driver_plans_only_for_personal_accounts(database):
    with database.session() as db, pytest.raises(HTTPException) as error:
        plans.assign(db, "driver.plus", company_id="c1")
    assert error.value.status_code == 422


def test_route_limit_per_month_and_unlimited_plan(database):
    with database.session() as db:
        plans.assign(db, "driver.start", subject="jan")
        plans.assign(db, "driver.startplus", subject="ewa", paid=True, billing="monthly")
        for _ in range(30):
            plans.count_route(db, "jan", NOW)
            plans.count_route(db, "ewa", NOW)

        with pytest.raises(HTTPException) as error:
            plans.count_route(db, "jan", NOW)
        assert error.value.status_code == 402
        assert "30 tras" in error.value.detail

        plans.count_route(db, "ewa", NOW)  # Start+ – bez limitu tras
        plans.count_route(db, "jan", NOW + timedelta(days=20))  # nowy miesiąc
        plans.count_route(db, "bez_planu", NOW)  # konto bez planu – bez limitu
        assert plans.routes_used(db, "jan", NOW) == 30


def test_members_limit_drivers_and_office_separately(database):
    with database.session() as db:
        plans.assign(db, "owner.small", company_id="c1", paid=True, billing="monthly")

        plans.check_member(db, "c1", "driver", {"owner": 1, "driver": 4})
        with pytest.raises(HTTPException):
            plans.check_member(db, "c1", "driver", {"owner": 1, "driver": 5})
        with pytest.raises(HTTPException):
            plans.check_member(db, "c1", "dispatcher", {"owner": 1, "dispatcher": 1, "driver": 0})
        plans.check_member(db, "bez_planu", "driver", {"driver": 500})


def test_trailers_counted_separately_from_powered_vehicles(database):
    with database.session() as db:
        plan = plans.assign(db, "owner.small", company_id="c1", paid=True, billing="monthly")

        plans.check_vehicle(db, plan, "semitrailer", powered=5, trailers=4)
        with pytest.raises(HTTPException):
            plans.check_vehicle(db, plan, "tractor", powered=5, trailers=0)
        with pytest.raises(HTTPException):
            plans.check_vehicle(db, plan, "trailer", powered=0, trailers=5)


def test_every_plan_has_a_name_in_every_language():
    from truckmaps.core import i18n

    for lang in ("pl", "en"):
        with i18n.use(lang):
            for plan in plans.PLANS:
                assert i18n.t(f"plan.{plan}") != f"plan.{plan}"
    assert Limits().vehicles is None
