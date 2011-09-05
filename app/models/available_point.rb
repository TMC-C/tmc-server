# Caches points that can be awarded from an exercise.
# Awarded points don't have a hard reference to these because
# these are recreated every time a course is refreshed.
class AvailablePoint < ActiveRecord::Base
  include Comparable

  belongs_to :exercise
  has_one :course, :through => :exercise

  def <=>(other)
    self.name.gsub(/\D/, '').to_i <=> other.name.gsub(/\D/, '').to_i
  end
end
