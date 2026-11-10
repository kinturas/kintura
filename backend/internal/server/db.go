package server

import (
	"context"

	"github.com/kinturas/kintura/backend/internal/database"
)

type dbtx = database.Querier

var boolColumns = map[string]bool{"done": true, "all_day": true, "yearly": true, "is_admin": true, "used": true, "is_sysadmin": true, "participants_all": true, "can_change_color": true, "managed": true}

// queryRows returns result rows keyed by column name, ready to be sent as JSON.
func queryRows(ctx context.Context, q dbtx, query string, args ...any) ([]map[string]any, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for rows.Next() {
		values := make([]any, len(cols))
		pointers := make([]any, len(cols))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			return nil, err
		}
		row := make(map[string]any, len(cols))
		for i, col := range cols {
			if n, ok := values[i].(int64); ok && boolColumns[col] {
				row[col] = n != 0
			} else if b, ok := values[i].([]byte); ok {
				row[col] = string(b)
			} else {
				row[col] = values[i]
			}
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

func isUniqueViolation(err error) bool { return database.IsUniqueViolation(err) }
