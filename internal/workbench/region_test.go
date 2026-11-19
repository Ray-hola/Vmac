package workbench

import (
	"context"
	"testing"

	"github.com/Ray-hola/Vmac/internal/cage"
	"github.com/Ray-hola/Vmac/internal/guestprofile"
)

func TestAutomaticRegionSettingsPreserveManualOverrides(t *testing.T) {
	cfg := cage.DefaultConfig()
	loc := Location{CountryCode: "JP", Timezone: "Asia/Tokyo"}
	manual := autoRegionSettings(cfg, Preferences{}, loc)
	if manual != cfg {
		t.Fatal("location changed manually selected settings")
	}
	tzOnly := autoRegionSettings(cfg, Preferences{AutoTimezone: true}, loc)
	if tzOnly.Timezone != "Asia/Tokyo" || tzOnly.Locale != cfg.Locale {
		t.Fatal("timezone option changed language")
	}
	languageOnly := autoRegionSettings(cfg, Preferences{AutoLanguage: true}, loc)
	if languageOnly.Locale != "ja_JP.UTF-8" || languageOnly.BrowserLanguage != "ja-JP" || languageOnly.Timezone != cfg.Timezone {
		t.Fatal("language option did not preserve independent timezone")
	}
	unknown := autoRegionSettings(cfg, Preferences{AutoLanguage: true}, Location{CountryCode: "ZZ"})
	if unknown != cfg {
		t.Fatal("unknown region invented a language setting")
	}
}

func TestMacOSStartupTimezoneUsesOnlyValidatedExit(t *testing.T) {
	cfg := cage.DefaultConfig()
	cfg.ExitPolicy = cage.ExitPolicy{Mode: "static", IP: "8.8.8.8"}
	for _, tc := range []struct {
		name, ip, country, observed, want string
	}{
		{"allowed exit", "8.8.8.8", "US", "America/New_York", "America/New_York"},
		{"different static exit", "1.1.1.1", "US", "America/New_York", cfg.Timezone},
		{"disallowed country", "8.8.8.8", "CN", "Asia/Shanghai", cfg.Timezone},
		{"no location", "", "", "", cfg.Timezone},
		{"unrecognized timezone", "8.8.8.8", "US", "America/Unknown", cfg.Timezone},
		{"host timezone alias", "8.8.8.8", "US", "Local", cfg.Timezone},
		{"equivalent timezone", "8.8.8.8", "US", "UTC", cfg.Timezone},
	} {
		t.Run(tc.name, func(t *testing.T) {
			observation := Location{IP: tc.ip, CountryCode: tc.country, Timezone: tc.observed}
			if got := macOSStartupTimezone(cfg, observation); got != tc.want {
				t.Fatalf("got timezone %s, want %s", got, tc.want)
			}
		})
	}
}

func TestMacOSStartupTimezonePersistsWithSavedGuestProfile(t *testing.T) {
	s := testServer(t)
	s.preferences.AutoTimezone = true
	if _, err := guestprofile.Create(s.profile, guestprofile.Options{}); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(s.configPath)
	if err != nil {
		t.Fatal(err)
	}
	const zone = "America/New_York"
	if err := s.applyMacOSStartupTimezone(context.Background(), cfg, zone, 0); err != nil {
		t.Fatal(err)
	}
	got, err := loadConfig(s.configPath)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Timezone = zone
	if got.Fingerprint() != cfg.Fingerprint() || got.GuestProfile == nil || *got.GuestProfile != *cfg.GuestProfile {
		t.Fatal("startup timezone changed unrelated configuration or did not persist")
	}
}

func TestMissingExitPolicyDoesNotRelaxSavedStaticRule(t *testing.T) {
	s := testServer(t)
	old := cage.DefaultConfig()
	old.ExitPolicy = cage.ExitPolicy{Mode: "static", Scope: "country", IP: "8.8.8.8"}
	input := settingsView(old, Preferences{Keyboard: "mac"})
	input.ExitPolicy = cage.ExitPolicy{}
	got, _, err := proposedSettings(input, old, s.profile)
	if err != nil {
		t.Fatal(err)
	}
	if got.ExitPolicy != old.ExitPolicy {
		t.Fatal("legacy form silently relaxed static IP")
	}
}
