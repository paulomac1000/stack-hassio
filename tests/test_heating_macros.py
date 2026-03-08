"""
Unit tests for data/hassio/custom_templates/heating_macros.jinja

Tests the two macros using Python's jinja2 library with mocked HA state/filter functions.
No Home Assistant instance required.

Macros tested:
  - heating_force_logic(temp_sensor, target_sensor, occupancy_type, occupancy_sensor)
    Returns True/False — whether heating should activate
  - heating_calibration_logic(temp_base_input, room)
    Returns float — adjusted target temperature

Run with: pytest tests/test_heating_macros.py -v
"""
import os

import jinja2
import pytest

TEMPLATES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    'data', 'hassio', 'custom_templates',
)

MACRO_FILE = 'heating_macros.jinja'


# ---------------------------------------------------------------------------
# HA environment factory
# ---------------------------------------------------------------------------

def make_env(state_map: dict, current_hour: int = 12) -> jinja2.Environment:
    """
    Create a Jinja2 environment that mimics HA's template context.

    state_map: entity_id → state value (str/int/float)
    current_hour: mocked value for now().hour
    """
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(TEMPLATES_DIR),
        keep_trailing_newline=False,
    )

    def is_state(entity: str, state: str) -> bool:
        return str(state_map.get(entity, 'off')) == str(state)

    def states(entity: str) -> str:
        return str(state_map.get(entity, 'unknown'))

    def float_filter(value, default=0.0):
        """HA adds a default argument to the float filter."""
        try:
            return float(value)
        except (ValueError, TypeError):
            return float(default)

    class _NowMock:
        def __init__(self, hour: int):
            self.hour = hour

    env.globals['is_state'] = is_state
    env.globals['states'] = states
    env.globals['now'] = lambda: _NowMock(current_hour)
    env.filters['float'] = float_filter

    return env


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _render_force_logic(
    state_map: dict,
    temp_current: float,
    temp_target: float,
    occupancy_type: str = 'normal',
    occupancy_sensor: str = 'binary_sensor.room_occupancy',
) -> bool:
    """Render heating_force_logic macro and return result as Python bool."""
    state_map = dict(state_map)
    state_map['sensor.temp_current'] = str(temp_current)
    state_map['sensor.temp_target'] = str(temp_target)

    env = make_env(state_map)
    tmpl = env.get_template(MACRO_FILE)

    src = (
        f"{{% from '{MACRO_FILE}' import heating_force_logic %}}"
        f"{{{{ heating_force_logic('sensor.temp_current', 'sensor.temp_target',"
        f" '{occupancy_type}', '{occupancy_sensor}') }}}}"
    )
    rendered = env.from_string(src).render().strip()
    return rendered == 'True'


def _render_calibration(
    state_map: dict,
    temp_base: float,
    room: str,
    current_hour: int = 12,
) -> float:
    """Render heating_calibration_logic macro and return result as Python float."""
    state_map = dict(state_map)
    state_map['sensor.temp_base'] = str(temp_base)

    env = make_env(state_map, current_hour=current_hour)
    src = (
        f"{{% from '{MACRO_FILE}' import heating_calibration_logic %}}"
        f"{{{{ heating_calibration_logic('sensor.temp_base', '{room}') | float }}}}"
    )
    rendered = env.from_string(src).render().strip()
    return float(rendered)


# ===========================================================================
# heating_force_logic — summer mode (no heating season)
# ===========================================================================

class TestForceLogicSummerMode:
    """When neither winter_mode nor pre_winter_mode is on → always False."""

    def test_always_false_regardless_of_temperature(self):
        states = {
            'input_boolean.winter_mode': 'off',
            'input_boolean.pre_winter_mode': 'off',
        }
        assert _render_force_logic(states, temp_current=18.0, temp_target=22.0) is False

    def test_always_false_even_when_very_cold(self):
        states = {
            'input_boolean.winter_mode': 'off',
            'input_boolean.pre_winter_mode': 'off',
        }
        assert _render_force_logic(states, temp_current=10.0, temp_target=24.0) is False

    def test_always_false_when_cheap_energy(self):
        states = {
            'input_boolean.winter_mode': 'off',
            'input_boolean.pre_winter_mode': 'off',
            'binary_sensor.energy_is_cheapest_1h_morning': 'on',
        }
        assert _render_force_logic(states, temp_current=15.0, temp_target=22.0) is False


# ===========================================================================
# heating_force_logic — winter mode
# ===========================================================================

class TestForceLogicWinterMode:
    BASE = {
        'input_boolean.winter_mode': 'on',
        'input_boolean.pre_winter_mode': 'off',
        'binary_sensor.room_occupancy': 'off',
        'binary_sensor.energy_is_cheapest_1h_morning': 'off',
        'sensor.energy_price_state': 'normal',
        'binary_sensor.energy_is_cheapest_5h': 'off',
        'sensor.ac_heating_economical_percentage': '100',
    }

    def test_heats_when_cold_and_affordable(self):
        # delta >= 0.8 and economical_pct(100) <= 120
        states = dict(self.BASE)
        assert _render_force_logic(states, temp_current=20.0, temp_target=21.0) is True

    def test_no_heat_when_economical_too_expensive(self):
        # is_cold_inside but economical_pct > 120 → first condition fails
        states = dict(self.BASE, **{'sensor.ac_heating_economical_percentage': '125'})
        result = _render_force_logic(states, temp_current=20.0, temp_target=21.0)
        # cheap morning is off, is_occupied is off → should be False
        assert result is False

    def test_heats_on_cheap_morning_regardless_of_delta(self):
        # is_cheap_morning and economical_pct(100) < 140
        states = dict(self.BASE, **{
            'binary_sensor.energy_is_cheapest_1h_morning': 'on',
            'sensor.ac_heating_economical_percentage': '100',
        })
        # temp at target — not cold
        assert _render_force_logic(states, temp_current=22.0, temp_target=22.0) is True

    def test_guest_sleeping_blocks_cheap_morning_heat(self):
        # is_guest_sleeping=True blocks morning boost in guest_mode
        states = dict(self.BASE, **{
            'binary_sensor.energy_is_cheapest_1h_morning': 'on',
            'binary_sensor.room_occupancy': 'on',  # guest_mode → is_guest_sleeping=True
        })
        result = _render_force_logic(
            states, temp_current=22.0, temp_target=22.0,
            occupancy_type='guest_mode',
            occupancy_sensor='binary_sensor.room_occupancy',
        )
        # is_guest_sleeping=True blocks morning boost; not cold enough for first branch
        assert result is False

    def test_no_heat_when_warm_and_not_occupied(self):
        # delta < 0.8 (not is_cold_inside), not occupied, no cheap morning
        states = dict(self.BASE)
        assert _render_force_logic(states, temp_current=21.5, temp_target=22.0) is False


# ===========================================================================
# heating_force_logic — pre-winter mode
# ===========================================================================

class TestForceLogicPreWinterMode:
    BASE = {
        'input_boolean.winter_mode': 'off',
        'input_boolean.pre_winter_mode': 'on',
        'binary_sensor.room_occupancy': 'off',
        'binary_sensor.energy_is_cheapest_1h_morning': 'off',
        'sensor.energy_price_state': 'normal',
        'binary_sensor.energy_is_cheapest_5h': 'off',
        'sensor.ac_heating_economical_percentage': '100',
    }

    def test_heats_when_cold_and_affordable(self):
        states = dict(self.BASE)
        assert _render_force_logic(states, temp_current=20.0, temp_target=21.0) is True

    def test_heats_when_occupied_and_cheap_hour(self):
        states = dict(self.BASE, **{
            'binary_sensor.room_occupancy': 'on',
            'sensor.energy_price_state': 'cheap',
        })
        assert _render_force_logic(states, temp_current=22.0, temp_target=22.0) is True

    def test_heats_when_occupied_and_very_economical(self):
        # economical_pct < 80 triggers even without cheap hour
        states = dict(self.BASE, **{
            'binary_sensor.room_occupancy': 'on',
            'sensor.ac_heating_economical_percentage': '75',
        })
        assert _render_force_logic(states, temp_current=22.0, temp_target=22.0) is True

    def test_no_heat_when_not_cold_not_occupied_not_cheap(self):
        states = dict(self.BASE)
        assert _render_force_logic(states, temp_current=21.5, temp_target=22.0) is False


# ===========================================================================
# heating_calibration_logic — livingroom
# ===========================================================================

class TestCalibrationLivingroom:
    BASE = {
        'input_boolean.sleeping_guest_livingroom': 'off',
        'sensor.pstryk_buy_price': '10',
        'sensor.ac_heating_economical_percentage': '100',
        'binary_sensor.energy_is_cheapest_1h_morning': 'off',
        'sensor.energy_price_state': 'normal',
        'binary_sensor.energy_is_cheapest_5h': 'off',
        'sensor.energy_cheap_today': 'unknown',
    }

    def test_baseline_no_boost(self):
        """When not cheap and not occupied by guest → base temp."""
        assert _render_calibration(self.BASE, temp_base=20.0, room='livingroom') == pytest.approx(20.0)

    def test_boost_when_negative_price(self):
        """Negative energy price → max boost (+5, capped at 24)."""
        states = dict(self.BASE, **{'sensor.pstryk_buy_price': '-1'})
        result = _render_calibration(states, temp_base=20.0, room='livingroom')
        assert result == pytest.approx(min(20.0 + 5, 24))

    def test_boost_capped_at_24(self):
        """Boost of +5 is capped at 24°C max."""
        states = dict(self.BASE, **{'sensor.pstryk_buy_price': '-1'})
        result = _render_calibration(states, temp_base=22.0, room='livingroom')
        assert result == pytest.approx(24.0)

    def test_small_boost_when_cheap_now(self):
        """Cheap hour → +1."""
        states = dict(self.BASE, **{
            'sensor.energy_price_state': 'cheap',
            'sensor.ac_heating_economical_percentage': '85',
        })
        result = _render_calibration(states, temp_base=20.0, room='livingroom')
        assert result == pytest.approx(21.0)

    def test_no_night_boost_outside_window(self):
        """Night cheap boost (1-6h) only applies within 1-6 AM window."""
        states = dict(self.BASE, **{'sensor.energy_price_state': 'cheap'})
        result_noon = _render_calibration(states, temp_base=20.0, room='livingroom', current_hour=12)
        result_night = _render_calibration(states, temp_base=20.0, room='livingroom', current_hour=3)
        # At noon: +1 (just cheap_now branch), at night 1-6h: +2
        assert result_noon == pytest.approx(21.0)
        assert result_night == pytest.approx(22.0)


# ===========================================================================
# heating_calibration_logic — bedroom
# ===========================================================================

class TestCalibrationBedroom:
    BASE = {
        'sensor.pstryk_buy_price': '10',
        'sensor.ac_heating_economical_percentage': '100',
        'binary_sensor.energy_is_cheapest_1h_morning': 'off',
        'sensor.energy_price_state': 'normal',
        'binary_sensor.energy_is_cheapest_5h': 'off',
    }

    def test_baseline_no_boost(self):
        assert _render_calibration(self.BASE, temp_base=18.0, room='bedroom') == pytest.approx(18.0)

    def test_boost_when_negative_price(self):
        states = dict(self.BASE, **{'sensor.pstryk_buy_price': '-1'})
        assert _render_calibration(states, temp_base=18.0, room='bedroom') == pytest.approx(20.0)

    def test_boost_cheap_morning(self):
        states = dict(self.BASE, **{
            'binary_sensor.energy_is_cheapest_1h_morning': 'on',
            'sensor.ac_heating_economical_percentage': '100',
        })
        assert _render_calibration(states, temp_base=18.0, room='bedroom') == pytest.approx(19.5)

    def test_boost_cheap_hour(self):
        states = dict(self.BASE, **{'sensor.energy_price_state': 'cheap'})
        assert _render_calibration(states, temp_base=18.0, room='bedroom') == pytest.approx(19.0)

    def test_boost_cheapest_5h_economical(self):
        states = dict(self.BASE, **{
            'binary_sensor.energy_is_cheapest_5h': 'on',
            'sensor.ac_heating_economical_percentage': '105',
        })
        assert _render_calibration(states, temp_base=18.0, room='bedroom') == pytest.approx(18.5)
