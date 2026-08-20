class AddCacheWriteTokensToTranslationRuns < ActiveRecord::Migration[8.0]
  def change
    # The counterpart to cache_read_tokens, and the one that can show the
    # caching design FAILING rather than succeeding.
    #
    # `input_tokens` carries only the uncached remainder -- total prompt is
    # input + cache_creation + cache_read -- so a run that wrote a 4,000-token
    # prefix at 1.25x and never read it back reports a tiny input and a zero
    # read, exactly like a run that cached nothing. Production run 4 wrote
    # ~41,500 tokens that way and the page said "cached: 0".
    #
    # Backfilling is not possible: the figure was never captured from the API
    # for runs that already exist. Those four rows keep the 0 default, which on
    # the run page reads as "wrote nothing" when the truth is "never measured".
    # Left as-is deliberately -- hiding the figure for legacy rows would cost
    # more complexity than four rows in one operator-only page are worth.
    add_column :translation_runs, :cache_write_tokens, :integer,
               :null => false, :default => 0
  end
end
