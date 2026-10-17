# Every combination the upstream knows about. The whole table (4 x 3 x 3 = 36)
# is fetched in one batch call, so this is both what users may ask for and
# what each refresh requests.
module RateCatalog
  PERIODS = %w[Summer Autumn Winter Spring].freeze
  HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  # [{ period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }, ...]
  ALL_ATTRIBUTES = PERIODS.product(HOTELS, ROOMS).map do |period, hotel, room|
    { period:, hotel:, room: }.freeze
  end.freeze
end
