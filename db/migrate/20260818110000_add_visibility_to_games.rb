# Backfilled in SQL rather than through the model: a data migration that
# instantiates Game would run today's validations against yesterday's rows,
# and this table holds games written before several of them existed.
#
# withdrawn_at is deliberately NOT consulted. Withdrawal is an orthogonal
# fact with its own column -- see the design, B2a.
class AddVisibilityToGames < ActiveRecord::Migration[8.0]
  def up
    add_column :games, :visibility, :string, :default => "draft", :null => false
    execute "UPDATE games SET visibility = CASE WHEN is_draft THEN 'draft' ELSE 'listed' END"
  end

  def down
    remove_column :games, :visibility
  end
end
