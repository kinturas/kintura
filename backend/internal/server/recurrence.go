package server

import (
	"net/http"
	"slices"
	"time"
)

// maxOccurrences limits what one series adds to a single answer.
const maxOccurrences = 1000

// recurrence describes how an event repeats. It always works on the wall clock of
// the event's time zone, so a weekly 10:00 stays at 10:00 across daylight saving.
type recurrence struct {
	Freq     string `json:"freq"` // day, week, month or year
	Interval int    `json:"interval"`
	Weekdays []int  `json:"weekdays,omitempty"` // week: 1 = Monday to 7 = Sunday
	MonthDay int    `json:"month_day,omitempty"`
	// MonthWeek selects "the first Monday" instead of a day: 1 to 4, or -1 for the last.
	MonthWeek    int `json:"month_week,omitempty"`
	MonthWeekday int `json:"month_weekday,omitempty"`
}

var errBadRecurrence = fail(http.StatusBadRequest, "Ungültige Wiederholung")

// normalize validates the rule and fills what follows from the first date.
func (rec *recurrence) normalize(first time.Time) error {
	if rec.Interval < 1 || rec.Interval > 999 {
		return errBadRecurrence
	}
	switch rec.Freq {
	case "day", "year":
		rec.Weekdays, rec.MonthDay, rec.MonthWeek, rec.MonthWeekday = nil, 0, 0, 0
	case "week":
		rec.MonthDay, rec.MonthWeek, rec.MonthWeekday = 0, 0, 0
		if len(rec.Weekdays) == 0 {
			rec.Weekdays = []int{isoWeekday(first)}
		}
		slices.Sort(rec.Weekdays)
		rec.Weekdays = slices.Compact(rec.Weekdays)
		if rec.Weekdays[0] < 1 || rec.Weekdays[len(rec.Weekdays)-1] > 7 {
			return errBadRecurrence
		}
	case "month":
		rec.Weekdays = nil
		if rec.MonthWeek != 0 {
			rec.MonthDay = 0
			if !slices.Contains([]int{-1, 1, 2, 3, 4}, rec.MonthWeek) || rec.MonthWeekday < 1 || rec.MonthWeekday > 7 {
				return errBadRecurrence
			}
			return nil
		}
		rec.MonthWeekday = 0
		if rec.MonthDay == 0 {
			rec.MonthDay = first.Day()
		}
		if rec.MonthDay < 1 || rec.MonthDay > 31 {
			return errBadRecurrence
		}
	default:
		return errBadRecurrence
	}
	return nil
}

func isoWeekday(t time.Time) int { return (int(t.Weekday())+6)%7 + 1 }

func daysInMonth(year int, month time.Month) int {
	return time.Date(year, month+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

// nthWeekday returns the day of the month of e.g. the first Monday (n = 1) or the
// last Friday (n = -1).
func nthWeekday(year int, month time.Month, n, weekday int) int {
	if n == -1 {
		last := daysInMonth(year, month)
		return last - (isoWeekday(time.Date(year, month, last, 0, 0, 0, 0, time.UTC))-weekday+7)%7
	}
	return 1 + (weekday-isoWeekday(time.Date(year, month, 1, 0, 0, 0, 0, time.UTC))+7)%7 + (n-1)*7
}

// starts returns the beginnings of all occurrences in [from, to), never before
// first, which also carries the time of day and the time zone. A day that a month
// does not have falls on its last day.
func (rec recurrence) starts(first, from, to time.Time) []time.Time {
	loc := first.Location()
	year, month, day := first.Date()
	hour, minute, _ := first.Clock()
	at := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, hour, minute, 0, 0, loc) }

	out := []time.Time{}
	// add keeps t if it is in range and reports whether to go on.
	add := func(t time.Time) bool {
		if !t.Before(to) || len(out) >= maxOccurrences {
			return false
		}
		if !t.Before(from) && !t.Before(first) {
			out = append(out, t)
		}
		return true
	}

	// Series can be decades old, so the loops jump close to from.
	fromYear, fromMonth, fromDay := from.In(loc).Date()
	daysUntil := int(time.Date(fromYear, fromMonth, fromDay, 0, 0, 0, 0, time.UTC).
		Sub(time.Date(year, month, day, 0, 0, 0, 0, time.UTC)) / (24 * time.Hour))

	switch rec.Freq {
	case "day":
		for k := max(0, daysUntil/rec.Interval); add(at(year, month, day+k*rec.Interval)); k++ {
		}
	case "week":
		monday := day - (isoWeekday(first) - 1)
		for k := max(0, (daysUntil+isoWeekday(first)-1)/(7*rec.Interval)); ; k++ {
			for _, weekday := range rec.Weekdays {
				if !add(at(year, month, monday+k*rec.Interval*7+weekday-1)) {
					return out
				}
			}
		}
	case "month", "year":
		step := rec.Interval
		if rec.Freq == "year" {
			step *= 12
		}
		monthsUntil := (fromYear-year)*12 + int(fromMonth-month)
		for k := max(0, monthsUntil/step); ; k++ {
			start := time.Date(year, month+time.Month(k*step), 1, 0, 0, 0, 0, time.UTC)
			y, m, _ := start.Date()
			var d int
			switch {
			case rec.MonthWeek != 0:
				d = nthWeekday(y, m, rec.MonthWeek, rec.MonthWeekday)
			case rec.Freq == "year":
				d = min(day, daysInMonth(y, m))
			default:
				d = min(rec.MonthDay, daysInMonth(y, m))
			}
			if !add(at(y, m, d)) {
				return out
			}
		}
	}
	return out
}

// wallClock keeps the digits of t and drops its time zone, which makes the length
// of an event independent of daylight saving.
func wallClock(t time.Time) time.Time {
	y, m, d := t.Date()
	hour, minute, sec := t.Clock()
	return time.Date(y, m, d, hour, minute, sec, 0, time.UTC)
}

// occurrenceEnd ends an occurrence as long after its start on the wall clock as
// the first occurrence.
func occurrenceEnd(occurrence time.Time, length time.Duration) time.Time {
	end := wallClock(occurrence).Add(length)
	y, m, d := end.Date()
	hour, minute, sec := end.Clock()
	return time.Date(y, m, d, hour, minute, sec, 0, occurrence.Location())
}
